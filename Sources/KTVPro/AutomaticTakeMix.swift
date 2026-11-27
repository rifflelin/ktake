import Accelerate
import AVFoundation
import Foundation

/// A rendered version owns its temporary WAV for as long as playback or export needs it.
final class AutomaticTakeMix: Sendable {
    enum Phase: String, Sendable {
        case analysis = "正在分析人声和伴奏…"
        case tuning = "正在处理人声…"
        case mixing = "正在平衡音量并渲染混音…"
    }

    let url: URL
    let pitch: VocalPitchCorrection.Result
    let leadBalanceDB: Float?
    let usedSavedReference: Bool
    var correctedPitch: Bool { pitch.adjustedSpans > 0 }
    private static let rate = AutomaticMixDSP.rate
    private static let block: AVAudioFrameCount = 2048

    private init(url: URL, pitch: VocalPitchCorrection.Result, leadBalanceDB: Float?, usedSavedReference: Bool) {
        self.url = url
        self.pitch = pitch
        self.leadBalanceDB = leadBalanceDB
        self.usedSavedReference = usedSavedReference
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static func prepare(from plan: TakeMix, applyPitch: Bool = true, vocalTrimDB: Float = 0,
                        progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> AutomaticTakeMix {
        let job = Task.detached(priority: .userInitiated) {
            try await render(plan, applyPitch: applyPitch, vocalTrimDB: vocalTrimDB, progress: progress)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    func exportWAV(to destination: URL) async throws {
        let job = Task.detached(priority: .userInitiated) { [self] in
            let files = FileManager.default
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".KTake-\(UUID()).wav")
            defer { try? files.removeItem(at: temporary) }
            try Task.checkCancellation()
            try files.copyItem(at: url, to: temporary)
            try Task.checkCancellation()
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try files.moveItem(at: temporary, to: destination)
            }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    private static func render(_ plan: TakeMix, applyPitch: Bool, vocalTrimDB: Float,
                               progress: (Phase) -> Void) async throws -> AutomaticTakeMix {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("KTake-auto-mix-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? files.removeItem(at: directory) } }
        let dry = directory.appendingPathComponent("dry.wav")
        let backing = directory.appendingPathComponent("backing.wav")
        let cleaned = directory.appendingPathComponent("clean.caf")
        let tuned = directory.appendingPathComponent("tuned.caf")
        let processed = directory.appendingPathComponent("processed.caf")
        let early = directory.appendingPathComponent("early.caf")
        let late = directory.appendingPathComponent("late.caf")
        let bus = directory.appendingPathComponent("vocal-bus.caf")
        let output = directory.appendingPathComponent("auto.wav")

        progress(.analysis)
        try plan.writeVocalStem(to: dry)
        try plan.writeBackingStem(to: backing)
        let voice = try profile(dry)
        let reference = try await prepareReference(from: plan, in: directory)

        progress(.tuning)
        try cleanVocal(dry, to: cleaned, profile: voice)
        try files.removeItem(at: dry)
        let pitch: VocalPitchCorrection.Result
        let analyzesPitch = applyPitch || reference != nil
        if analyzesPitch {
            pitch = try VocalPitchCorrection.render(from: cleaned, to: tuned, noiseDB: voice.quietDB + voice.gainDB,
                                                     reference: reference, applyPitch: applyPitch)
        } else {
            pitch = VocalPitchCorrection.Result()
        }
        try processVocal(analyzesPitch ? tuned : cleaned, to: processed, profile: voice,
                         referenceDynamics: reference?.dynamicRangeDB)
        if analyzesPitch { try files.removeItem(at: tuned) }
        progress(.mixing)
        let beat = try detectBeat(backing)
        try AutomaticMixDSP.renderHall(voice: processed, early: early, late: late, directory: directory)
        try renderVocalBus(voice: processed, early: early, late: late, activity: cleaned, profile: voice,
                           delaySeconds: beat.map { $0 / 2 } ?? reference?.echo?.seconds ?? 0.30, to: bus)
        for temporary in [processed, early, late] { try files.removeItem(at: temporary) }
        let balance = try balance(voice: bus, backing: backing, activity: cleaned,
                                  activityDB: voice.activityDB + voice.gainDB,
                                  reference: reference, vocalTrimDB: vocalTrimDB.isFinite ? min(6, max(-6, vocalTrimDB)) : 0)
        try files.removeItem(at: cleaned)
        try writeMaster(voice: bus, backing: backing, balance: balance, to: output)
        try Task.checkCancellation()
        for temporary in [backing, bus] { try files.removeItem(at: temporary) }
        completed = true
        return AutomaticTakeMix(url: output, pitch: pitch, leadBalanceDB: balance.leadDB, usedSavedReference: reference?.isIsolated == true)
    }

    private static func prepareReference(from plan: TakeMix, in directory: URL) async throws -> VocalPitchCorrection.Reference? {
        let original = directory.appendingPathComponent("reference-mix.wav")
        let backing = directory.appendingPathComponent("reference-instrumental.wav")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: backing)
        }
        for isolated in [true, false] {
            do {
                guard let shift = try await plan.writeReferenceStems(vocalSource: original, instrumental: backing,
                                                                     sampleRate: VocalPitchCorrection.referenceSampleRate,
                                                                     isolated: isolated) else { continue }
                if let reference = try VocalPitchCorrection.analyzeReference(original: original, instrumental: backing,
                                                                            semitones: shift, isolated: isolated) {
                    return reference
                }
            } catch {
                try Task.checkCancellation()
            }
        }
        return nil
    }

    private struct VoiceProfile {
        let quietDB: Float
        let activityDB: Float
        let typicalDB: Float
        let compressorDB: Float
        let gainDB: Float
        let dynamicRangeDB: Float
    }

    private static func profile(_ source: URL) throws -> VoiceProfile {
        let input = try open(source)
        let buffer = try makeBuffer(input)
        var histogram = Array(repeating: 0, count: 101)
        var peak: Float = 0
        while try read(input, into: buffer) {
            let samples = buffer.floatChannelData![0]
            let count = vDSP_Length(buffer.frameLength)
            var blockPeak: Float = 0
            vDSP_maxmgv(samples, 1, &blockPeak, count)
            peak = max(peak, blockPeak)
            let db = Int(powerDB(energy(buffer) / Float(buffer.frameLength)).rounded())
            histogram[min(100, max(0, db + 100))] += 1
        }
        func percentile(_ fraction: Double, above minimum: Int = -100) -> Float {
            let start = max(0, minimum + 100)
            let total = histogram[start...].reduce(0, +)
            let rank = max(1, Int((Double(total) * fraction).rounded(.up)))
            var seen = 0
            for bin in start..<histogram.count {
                seen += histogram[bin]
                if seen >= rank { return Float(bin - 100) }
            }
            return Float(minimum)
        }
        let high = percentile(0.9)
        // A short vocal over a long lead-in can be below the whole-file 90th percentile.
        let strongest = histogram.lastIndex(where: { $0 > 0 }).map { Float($0 - 100) } ?? -100
        guard strongest > -62 else { throw AppFailure(message: "录音里没有足够清楚的人声可供处理。") }
        let floor = min(-42, percentile(0.2), max(high, strongest - 8) - 24)
        let active = max(-66, floor + 8, max(high, strongest - 12) - 20)
        let middle = percentile(0.5, above: Int(active))
        let gain = min(15, max(-10, -20 - middle), -2 - 20 * log10f(max(peak, 0.00001)))
        let dynamicRange = percentile(0.9, above: Int(active)) - percentile(0.3, above: Int(active))
        let compressor = percentile(0.66, above: Int(active)) + gain
        return VoiceProfile(quietDB: floor, activityDB: active, typicalDB: middle + gain, compressorDB: compressor, gainDB: gain,
                            dynamicRangeDB: dynamicRange)
    }

    private static func cleanVocal(_ source: URL, to destination: URL, profile: VoiceProfile) throws {
        let input = try open(source)
        let output = try makeFloatFile(destination, format: input.processingFormat)
        let buffer = try makeBuffer(input)
        let gain = powf(10, profile.gainDB / 20)
        var highPass = AutomaticMixDSP.Filter.highPass(83)
        var body = AutomaticMixDSP.Filter.bell(420, q: 0.88, db: -2.1)
        var clarity = AutomaticMixDSP.Filter.shelf(3630, db: 1.9, slope: 0.59)
        var level: Float = 0
        var gate: Float = 1
        let quiet = powf(10, (profile.quietDB + 5) / 20)
        while try read(input, into: buffer) {
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                let highPassed = highPass.process(samples[i])
                level += (abs(highPassed) > level ? 0.006 : 0.00023) * (abs(highPassed) - level)
                let target = 0.82 + 0.18 * min(1, level / max(quiet * 1.5, 0.00001))
                gate += (target > gate ? 0.007 : 0.00020) * (target - gate)
                samples[i] = clarity.process(body.process(highPassed)) * gate * gain
            }
            try output.write(from: buffer)
        }
    }

    private static func processVocal(_ source: URL, to destination: URL, profile: VoiceProfile, referenceDynamics: Float?) throws {
        let input = try open(source)
        let output = try makeFloatFile(destination, format: input.processingFormat)
        let buffer = try makeBuffer(input)
        let strength = referenceDynamics.map { min(1, max(0.40, 0.80 + (profile.dynamicRangeDB - $0) / 20)) } ?? 0.85
        var detector = AutomaticMixDSP.Envelope(attack: 0.020, release: 0.020)
        var quick = AutomaticMixDSP.Envelope(attack: 0.010, release: 0.065, rate: 1000)
        var slow = AutomaticMixDSP.Envelope(attack: 0.035, release: 0.370, rate: 1000)
        var color = AutomaticMixDSP.Filter.bell(4200, q: 0.83, db: 0.8)
        var harsh = AutomaticMixDSP.Filter.bell(6000, q: 0.90, db: -0.85)
        var air = AutomaticMixDSP.Filter.shelf(13800, db: 4, slope: 0.85)
        var saturation = AutomaticMixDSP.Saturation()
        var essHigh = AutomaticMixDSP.Filter.highPass(4200)
        var essLow = AutomaticMixDSP.Filter.lowPass(13300)
        var essLevel = AutomaticMixDSP.Envelope(attack: 0.0035, release: 0.007)
        var broadLevel = AutomaticMixDSP.Envelope(attack: 0.011, release: 0.011)
        var deEss = AutomaticMixDSP.Envelope(attack: 0.0018, release: 0.031, rate: 1000)
        var control = 0
        var compression: Float = 1, compressionStep: Float = 0
        var deEssGain: Float = 1, deEssStep: Float = 0
        while try read(input, into: buffer) {
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                let direct = samples[i]
                let power = detector.track(direct * direct)
                if control == 0 {
                    let above = powerDB(power) - profile.compressorDB
                    let knee = above > 2 ? above : powf(max(0, above + 2), 2) / 8
                    let desired = min(5.1, knee * 0.62) * strength
                    let reduction = quick.track(desired) * 0.72 + slow.track(desired) * 0.28
                    compressionStep = (amplitude(-reduction) - compression) / 48
                }
                compression += compressionStep
                let colored = saturation.process(air.process(harsh.process(color.process(direct * compression))))
                let ess = essLow.process(essHigh.process(colored))
                let relative = sqrtf(essLevel.track(ess * ess)) / max(0.02, sqrtf(broadLevel.track(colored * colored)))
                if control == 0 {
                    let reduction = deEss.track(2.35 * AutomaticMixDSP.smooth((relative - 0.47) / 0.29))
                    deEssStep = (amplitude(-reduction) - deEssGain) / 48
                }
                deEssGain += deEssStep
                samples[i] = colored * deEssGain
                control += 1
                if control == 48 { control = 0 }
            }
            try output.write(from: buffer)
        }
    }

    private static func detectBeat(_ source: URL) throws -> Float? {
        let input = try open(source)
        let buffer = try makeBuffer(input)
        var meter = try AutomaticMixDSP.Tempo()
        // Eight minutes is enough material to estimate one beat for this render.
        while input.framePosition < 8 * 60 * Int64(rate), try read(input, into: buffer) {
            let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
            for i in 0..<Int(buffer.frameLength) { meter.add((left[i] + right[i]) * 0.5) }
        }
        return meter.beatSeconds()
    }

    private static func renderVocalBus(voice: URL, early: URL, late: URL, activity: URL, profile: VoiceProfile,
                                       delaySeconds: Float, to destination: URL) throws {
        let voice = try open(voice), early = try open(early), late = try open(late), activity = try open(activity)
        let dry = try makeBuffer(voice), reflections = try makeBuffer(early), tail = try makeBuffer(late)
        let meter = try makeBuffer(activity)
        let stereo = try makeBuffer(early)
        let output = try makeFloatFile(destination, format: early.processingFormat)
        let typical = amplitude(profile.typicalDB)
        let threshold = amplitude(profile.activityDB + profile.gainDB + 4)
        let delay = min(0.50, max(0.17, delaySeconds))
        var voicePower: Double = 0
        var effectPower = SIMD4<Double>.zero
        var send = SIMD4<Float>.zero
        let targets = SIMD4(amplitude(-24), amplitude(-27), amplitude(-28.2), amplitude(-28.5))
        for measureOnly in [true, false] {
            voice.framePosition = 0
            early.framePosition = 0
            late.framePosition = 0
            activity.framePosition = 0
            var effects = AutomaticMixDSP.Space(delaySeconds: delay)
            while try read(voice, into: dry) {
                let frames = dry.frameLength
                try readAligned(early, into: reflections, count: frames)
                try readAligned(late, into: tail, count: frames)
                try readAligned(activity, into: meter, count: frames)
                stereo.frameLength = frames
                let isActive = energy(meter) > threshold * threshold * Float(frames)
                let samples = dry.floatChannelData![0]
                let earlyL = reflections.floatChannelData![0], earlyR = reflections.floatChannelData![1]
                let lateL = tail.floatChannelData![0], lateR = tail.floatChannelData![1]
                let left = stereo.floatChannelData![0], right = stereo.floatChannelData![1]
                for i in 0..<Int(frames) {
                    let direct = samples[i]
                    let effect = effects.process(direct, typical: typical)
                    let first = SIMD2(earlyL[i], earlyR[i])
                    let second = SIMD2(lateL[i], lateR[i]) * (1 + 0.175 * effect.openness)
                    if measureOnly {
                        if isActive {
                            voicePower += Double(direct * direct)
                            let l = SIMD4(first.x, second.x, effect.echo.x, effect.double.x)
                            let r = SIMD4(first.y, second.y, effect.echo.y, effect.double.y)
                            effectPower += SIMD4<Double>((l * l + r * r) * 0.5)
                        }
                    } else {
                        let mixed = SIMD2(repeating: direct) + first * send[0] + second * send[1]
                            + effect.echo * send[2] + effect.double * send[3]
                        left[i] = mixed.x
                        right[i] = mixed.y
                    }
                }
                if !measureOnly { try output.write(from: stereo) }
            }
            if measureOnly {
                for index in 0..<4 where effectPower[index] > 1e-8 {
                    send[index] = min(4, targets[index] * Float(sqrt(voicePower / effectPower[index])))
                }
            }
        }
    }

    private struct Balance {
        let voice: Float
        let backing: Float
        let leadDB: Float?
        let ride: VocalRide
    }

    private struct VocalRide {
        static let framesPerPoint = 2 * rate
        let gains: [Float]

        func gain(at sample: Int64) -> Float {
            guard !gains.isEmpty else { return 1 }
            let frames = Int64(Self.framesPerPoint)
            let index = min(gains.count - 1, Int(sample / frames))
            let next = min(gains.count - 1, index + 1)
            let fraction = Float(sample % frames) / Float(frames)
            return gains[index] + fraction * (gains[next] - gains[index])
        }
    }

    private static func balance(voice: URL, backing: URL, activity: URL, activityDB: Float,
                                reference: VocalPitchCorrection.Reference?, vocalTrimDB: Float) throws -> Balance {
        let voice = try open(voice), backing = try open(backing), activity = try open(activity)
        let windows = VocalPitchCorrection.Reference.mixBlockFrames
        let vocal = try makeBuffer(voice, capacity: AVAudioFrameCount(windows))
        let music = try makeBuffer(backing, capacity: AVAudioFrameCount(windows))
        let active = try makeBuffer(activity, capacity: AVAudioFrameCount(windows))
        var ownLeft = VocalBalanceBand(sampleRate: Float(rate)), ownRight = VocalBalanceBand(sampleRate: Float(rate))
        var musicLeft = VocalBalanceBand(sampleRate: Float(rate)), musicRight = VocalBalanceBand(sampleRate: Float(rate))
        var eqLeft = AutomaticMixDSP.Filter.bell(405, q: 1, db: -1.4)
        var eqRight = AutomaticMixDSP.Filter.bell(405, q: 1, db: -1.4)
        var comparisons: [(sample: Int64, blended: Float, original: Float?)] = []
        var vocalDifferences = Array(repeating: [Float](), count: Int(voice.length) / VocalRide.framesPerPoint + 2)
        var musicPower: Double = 0, voicePower: Double = 0
        var musicFrames = 0, voiceFrames = 0
        let threshold = amplitude(activityDB + 4)
        while try read(voice, into: vocal) {
            let frames = vocal.frameLength
            try readAligned(backing, into: music, count: frames)
            try readAligned(activity, into: active, count: frames)
            let count = Int(frames)
            let left = vocal.floatChannelData![0], right = vocal.floatChannelData![1]
            let backingL = music.floatChannelData![0], backingR = music.floatChannelData![1]
            var voiceBand: Float = 0, musicBand: Float = 0, backingEnergy: Float = 0
            for i in 0..<count {
                let a = ownLeft.filter(left[i]), b = ownRight.filter(right[i])
                voiceBand += (a * a + b * b) * 0.5
                let l = eqLeft.process(backingL[i]), r = eqRight.process(backingR[i])
                let x = musicLeft.filter(l), y = musicRight.filter(r)
                musicBand += (x * x + y * y) * 0.5
                backingEnergy += (l * l + r * r) * 0.5
            }
            guard energy(active) > threshold * threshold * Float(count) else { continue }
            voicePower += Double(energy(vocal))
            voiceFrames += count
            guard backingEnergy > Float(count) * 0.00001 else { continue }
            musicPower += Double(backingEnergy)
            musicFrames += count
            guard musicBand > Float(count) * 0.000005, voiceBand > Float(count) * 0.000001 else { continue }
            let midpoint = voice.framePosition - Int64(count / 2)
            let measured = reference?.mixLevel(at: midpoint)
            let lead = powerDB(voiceBand / Float(count))
            if let measured {
                let point = (Int(midpoint) + VocalRide.framesPerPoint / 2) / VocalRide.framesPerPoint
                vocalDifferences[point].append(measured.vocalDB - lead)
            }
            comparisons.append((midpoint, powerDB(voiceBand / musicBand), measured?.balanceDB))
        }

        let backingRMS = Float(sqrt(musicPower / Double(max(1, musicFrames))))
        let voiceRMS = Float(sqrt(voicePower / Double(max(1, voiceFrames))))
        let backingGain = min(1.25, max(0.18, 0.133 / max(backingRMS, 0.001)))
        let differences = vocalDifferences.flatMap { $0 }.sorted()
        let ride: VocalRide
        if differences.count >= 12 {
            let center = differences[differences.count / 2]
            let points = vocalDifferences.indices.map { index -> Float in
                let lower = max(0, index - 1), upper = min(index + 1, vocalDifferences.count - 1)
                let local = vocalDifferences[lower...upper].flatMap { $0 }.sorted()
                guard local.count >= 6 else { return 1 }
                let delta = local[local.count / 2] - center
                return amplitude(min(1.4, max(-1.4, delta * 0.38)))
            }
            ride = VocalRide(gains: points)
        } else {
            ride = VocalRide(gains: [])
        }

        let withReference = comparisons.filter { $0.original != nil }
        let measured = withReference.count >= 12 ? withReference : comparisons
        let original = withReference.compactMap(\.original).sorted()
        let target: Float = withReference.count >= 12 ? min(5, max(-7, original[original.count / 2] + 0.25)) : -1
        let ratios = measured.map { $0.blended + 20 * log10f(ride.gain(at: $0.sample)) }.sorted()
        let voiceGain: Float
        if ratios.count >= 4 {
            voiceGain = min(5, max(0.16, backingGain * amplitude(target - ratios[ratios.count / 2])))
        } else {
            voiceGain = min(5, max(0.16, 0.10 / max(voiceRMS, 0.001)))
        }
        let trimmed = voiceGain * amplitude(vocalTrimDB)
        let actual = ratios.count >= 4 ? ratios[ratios.count / 2] + 20 * log10f(trimmed / backingGain) : nil
        return Balance(voice: trimmed, backing: backingGain, leadDB: actual, ride: ride)
    }

    private static func writeMaster(voice: URL, backing: URL, balance: Balance, to destination: URL) throws {
        let voice = try open(voice), backing = try open(backing)
        let lead = try makeBuffer(voice), music = try makeBuffer(backing), outputBuffer = try makeBuffer(backing)
        var settings = backing.processingFormat.settings
        settings[AVLinearPCMBitDepthKey] = 24
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let outLeft = outputBuffer.floatChannelData![0], outRight = outputBuffer.floatChannelData![1]
        var peak: Float = 0
        var outputCount = 0
        func append(_ sample: SIMD2<Float>) throws {
            outLeft[outputCount] = sample.x
            outRight[outputCount] = sample.y
            outputCount += 1
            if outputCount == Int(outputBuffer.frameCapacity) {
                outputBuffer.frameLength = AVAudioFrameCount(outputCount)
                try output.write(from: outputBuffer)
                outputCount = 0
            }
        }

        for measureOnly in [true, false] {
            voice.framePosition = 0
            backing.framePosition = 0
            var eqLeft = AutomaticMixDSP.Filter.bell(405, q: 1, db: -1.4)
            var eqRight = AutomaticMixDSP.Filter.bell(405, q: 1, db: -1.4)
            var meter = AutomaticMixDSP.PeakMeter()
            var limiter = AutomaticMixDSP.Limiter(peak: peak)
            var elapsed = 0
            while try read(voice, into: lead) {
                let count = lead.frameLength
                try readAligned(backing, into: music, count: count)
                let vocalL = lead.floatChannelData![0], vocalR = lead.floatChannelData![1]
                let songL = music.floatChannelData![0], songR = music.floatChannelData![1]
                var gain = balance.ride.gain(at: voice.framePosition - Int64(count))
                let step = (balance.ride.gain(at: voice.framePosition) - gain) / Float(count)
                for i in 0..<Int(count) {
                    let music = SIMD2(eqLeft.process(songL[i]), eqRight.process(songR[i])) * balance.backing
                    let mix = music + SIMD2(vocalL[i], vocalR[i]) * (balance.voice * gain)
                    gain += step
                    if measureOnly {
                        peak = max(peak, meter.peak(mix))
                    } else {
                        let sample = limiter.process(mix)
                        if elapsed >= AutomaticMixDSP.Limiter.lookahead { try append(sample) }
                        elapsed += 1
                    }
                }
            }
            if measureOnly {
                for _ in 0..<3 { peak = max(peak, meter.peak(.zero)) }
            } else {
                for _ in 0..<AutomaticMixDSP.Limiter.lookahead {
                    let sample = limiter.process(.zero)
                    if elapsed >= AutomaticMixDSP.Limiter.lookahead { try append(sample) }
                    elapsed += 1
                }
                if outputCount > 0 {
                    outputBuffer.frameLength = AVAudioFrameCount(outputCount)
                    try output.write(from: outputBuffer)
                }
            }
        }
    }

    private static func amplitude(_ db: Float) -> Float { powf(10, db / 20) }

    private static func open(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func makeFloatFile(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func makeBuffer(_ file: AVAudioFile, capacity: AVAudioFrameCount = block) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw AppFailure(message: "无法准备自动混音缓冲区。")
        }
        return buffer
    }

    private static func read(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer) throws -> Bool {
        try Task.checkCancellation()
        guard file.framePosition < file.length else { return false }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw AppFailure(message: "无法完整读取待处理的音轨。") }
        return true
    }

    private static func readAligned(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer, count: AVAudioFrameCount) throws {
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength == count else { throw AppFailure(message: "自动混音音轨长度不一致。") }
    }

    private static func energy(_ buffer: AVAudioPCMBuffer) -> Float {
        var sum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var power: Float = 0
            vDSP_svesq(buffer.floatChannelData![channel], 1, &power, vDSP_Length(buffer.frameLength))
            sum += power
        }
        return sum / Float(buffer.format.channelCount)
    }

    private static func powerDB(_ power: Float) -> Float { 10 * log10f(max(0.0000000001, power)) }
}
