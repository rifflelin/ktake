import Accelerate
import AVFoundation
import Foundation

/// Approximate the range where a lead vocal competes with the accompaniment's center.
struct VocalBalanceBand {
    private let highPass: Float
    private let lowPass: Float
    private var bass: Float = 0
    private var band: Float = 0

    init(sampleRate: Float) {
        highPass = 1 - expf(-2 * .pi * 125 / sampleRate)
        lowPass = 1 - expf(-2 * .pi * 3400 / sampleRate)
    }

    mutating func filter(_ sample: Float) -> Float {
        bass += highPass * (sample - bass)
        band += lowPass * (sample - bass - band)
        return band
    }
}

/// Offline, single-voice correction. Adjust sustained note centers while keeping
/// the pitch movement within each note and the original timing.
enum VocalPitchCorrection {
    private static let rate = 48_000
    private static let decimation = 6
    private static let hop = 960
    private static let fade = 1920
    static let referenceSampleRate = Int32(rate / decimation)

    struct Reference {
        fileprivate let events: [NoteEvent]
        let leadBalanceDB: Float?
        fileprivate let mixLevels: [MixLevel?]
        let dynamicRangeDB: Float?
        let tailDB: Float?
        let lateTailDB: Float?
        let echo: Echo?
        let isIsolated: Bool

        static let mixBlockFrames = VocalPitchCorrection.rate / 5

        struct MixLevel {
            let vocalDB: Float
            let balanceDB: Float
        }

        func mixLevel(at sample: Int64) -> MixLevel? {
            let index = Int(sample / Int64(Self.mixBlockFrames))
            return mixLevels.indices.contains(index) ? mixLevels[index] : nil
        }
    }

    struct Echo {
        let seconds: Float
        let gain: Float
    }

    struct Discrepancy: Identifiable, Sendable {
        let start: Double
        var end: Double
        let sung: Int
        let target: Int
        let corrected: Bool
        var id: Double { start }

        var notesLabel: String { "\(Self.name(sung)) → \(Self.name(target))" }

        private static func name(_ note: Int) -> String {
            let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            return names[(note % 12 + 12) % 12] + String(note / 12 - 1)
        }
    }

    struct Result: Sendable {
        var adjustedSpans = 0
        var comparedReference = false
        var discrepancies: [Discrepancy] = []

        mutating func append(_ item: Discrepancy) {
            if let previous = discrepancies.last, previous.sung == item.sung, previous.target == item.target,
               item.start - previous.end <= 0.081, previous.corrected == item.corrected {
                discrepancies[discrepancies.count - 1].end = item.end
            } else {
                discrepancies.append(item)
            }
        }
    }

    private struct Pitch {
        var hz: Float = 0
        var note: Float = 0
    }

    fileprivate struct NoteEvent {
        let frames: Range<Int>
        let center: Float
        let spread: Float
        var note: Int { Int(center.rounded()) }
        var midpoint: Float { Float(frames.lowerBound + frames.upperBound) * 0.5 }
    }

    static func analyzeReference(original: URL, instrumental: URL, semitones: Int, isolated: Bool = false) throws -> Reference? {
        let song = try AVAudioFile(forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
        let backing = try AVAudioFile(forReading: instrumental, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = song.processingFormat.channelCount
        guard song.length == backing.length, (-6...6).contains(semitones), (1...2).contains(channels),
              song.processingFormat.sampleRate == Double(referenceSampleRate),
              backing.processingFormat.sampleRate == Double(referenceSampleRate), backing.processingFormat.channelCount == channels,
              let buffer = AVAudioPCMBuffer(pcmFormat: song.processingFormat, frameCapacity: 4096) else { return nil }
        let total = Int(song.length)

        func read(_ input: AVAudioFile, from start: Int, count: Int) throws -> [Float] {
            input.framePosition = Int64(start)
            var samples: [Float] = []
            samples.reserveCapacity(count)
            while samples.count < count {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(count - samples.count)))
                guard buffer.frameLength > 0, let frames = buffer.floatChannelData?[0] else {
                    throw AppFailure(message: "无法读取完整的原唱参考音频。")
                }
                let length = Int(buffer.frameLength)
                if channels == 2, let right = buffer.floatChannelData?[1] {
                    for i in 0..<length { samples.append((frames[i] + right[i]) * 0.5) }
                } else {
                    samples.append(contentsOf: UnsafeBufferPointer(start: frames, count: length))
                }
            }
            return samples
        }

        let gain: Float
        if isolated {
            gain = 1
        } else {
            // The separator can scale the saved accompaniment down to avoid clipping.
            // Estimate that gain from sections dominated by matching accompaniment.
            let calibration = Int(referenceSampleRate) / 5
            var gains: [Float] = []
            for start in stride(from: 0, to: total - calibration + 1, by: calibration) {
                let source = try read(song, from: start, count: calibration)
                let music = try read(backing, from: start, count: calibration)
                let count = vDSP_Length(calibration)
                var sourcePower: Float = 0, musicPower: Float = 0, dot: Float = 0
                vDSP_svesq(source, 1, &sourcePower, count)
                vDSP_svesq(music, 1, &musicPower, count)
                vDSP_dotpr(source, 1, music, 1, &dot, count)
                guard musicPower / Float(calibration) > 0.00004, dot > 0.89 * sqrtf(sourcePower * musicPower) else { continue }
                let gain = dot / musicPower
                if (0.8...1.8).contains(gain) { gains.append(gain) }
            }
            guard gains.count >= 2 else { return nil }
            gains.sort()
            // Small estimates around unity can come from voice bleeding into calibration windows.
            let estimatedGain = gains[gains.count / 2]
            gain = abs(estimatedGain - 1) <= 0.035 ? 1 : estimatedGain
        }
        let step = hop / decimation
        let block = Int(referenceSampleRate) * 8
        let context = step * 3
        var notes: [Float?] = []
        var vocalLevels: [Float?] = []
        var balances: [Float] = []
        var levels: [Float] = []
        notes.reserveCapacity((total + step - 1) / step)
        var scratch = Array(repeating: Float(1), count: 124)
        for start in stride(from: 0, to: total, by: block) {
            let end = min(total, start + block)
            let before = max(0, start - context)
            let after = min(total, end + context)
            let source = try read(song, from: before, count: after - before)
            let music = try read(backing, from: before, count: after - before)
            var residual = source
            var subtract = -gain
            if !isolated {
                vDSP_vsma(music, 1, &subtract, source, 1, &residual, 1, vDSP_Length(residual.count))
            }
            var voiceMeter = VocalBalanceBand(sampleRate: Float(referenceSampleRate))
            var musicMeter = VocalBalanceBand(sampleRate: Float(referenceSampleRate))
            let voiceBand = residual.map { voiceMeter.filter($0) }
            let musicBand = music.map { musicMeter.filter($0) * gain }
            try residual.withUnsafeBufferPointer { residual in
                try music.withUnsafeBufferPointer { music in
                    for frame in stride(from: start, to: end, by: step) {
                        if notes.count.isMultiple(of: 32) { try Task.checkCancellation() }
                        var vocalLevel: Float?
                        defer { vocalLevels.append(vocalLevel) }
                        let center = frame - before
                        guard center >= 80, center + 80 <= residual.count else {
                            notes.append(nil)
                            levels.append(-100)
                            continue
                        }
                        var remaining: Float = 0, accompaniment: Float = 0
                        vDSP_svesq(residual.baseAddress! + center - 80, 1, &remaining, 160)
                        vDSP_svesq(music.baseAddress! + center - 80, 1, &accompaniment, 160)
                        levels.append(10 * log10f(max(1e-10, remaining / 160)))
                        let leakageFloor: Float = isolated ? 0 : accompaniment * 0.012
                        guard remaining >= max(0.00256, leakageFloor) else { notes.append(nil); continue }
                        let pitch = estimatePitch(residual, center: center, minimumLevel: 0.004, scratch: &scratch)
                        notes.append(pitch.hz > 0 ? pitch.note + Float(semitones) : nil)
                        if pitch.hz > 0 {
                            let window = (center - 80)..<(center + 80)
                            let vocalPower = voiceBand[window].reduce(Float(0)) { $0 + $1 * $1 }
                            if vocalPower > 0.0016 {
                                vocalLevel = 10 * log10f(vocalPower / (160 * gain * gain))
                                if notes.count.isMultiple(of: 3) {
                                    let backingPower = musicBand[window].reduce(Float(0)) { $0 + $1 * $1 }
                                    if backingPower > 0.0016 {
                                        let db = 10 * log10f(vocalPower / backingPower)
                                        if (-18...16).contains(db) { balances.append(db) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let events = referenceEvents(notes)
        guard !events.isEmpty else { return nil }
        let referenceLevels = vocalLevels.compactMap { $0 }.sorted()
        if !referenceLevels.isEmpty {
            let floor = referenceLevels[referenceLevels.count * 4 / 5] - 15
            vocalLevels = vocalLevels.map { value in value.flatMap { $0 >= floor ? $0 : nil } }
        }
        balances.sort()
        let balance = balances.count >= 20 ? balances[balances.count / 2] : nil
        let voicedLevels = events.flatMap { event -> [Float] in
            let trim = event.frames.count / 5
            return Array(levels[(event.frames.lowerBound + trim)..<(event.frames.upperBound - trim)])
        }.sorted()
        let range = voicedLevels.count >= 30 ?
            voicedLevels[voicedLevels.count * 9 / 10] - voicedLevels[voicedLevels.count * 3 / 10] : nil
        let tail = isolated ? estimateTail(events: events, levels: levels) : nil
        let echo = isolated ? try estimateEcho(levels: levels) { start, count in
            try read(song, from: start, count: count)
        } : nil
        let mixLevels = try measureMixLevels(song: song, backing: backing, gain: gain, isolated: isolated,
                                            vocalLevels: vocalLevels)
        return Reference(events: events, leadBalanceDB: balance, mixLevels: mixLevels,
                         dynamicRangeDB: range, tailDB: tail?.early, lateTailDB: tail?.late, echo: echo, isIsolated: isolated)
    }

    private static func measureMixLevels(song: AVAudioFile, backing: AVAudioFile, gain: Float, isolated: Bool,
                                         vocalLevels: [Float?]) throws -> [Reference.MixLevel?] {
        let frames = AVAudioFrameCount(referenceSampleRate / 5)
        guard let voice = AVAudioPCMBuffer(pcmFormat: song.processingFormat, frameCapacity: frames),
              let music = AVAudioPCMBuffer(pcmFormat: backing.processingFormat, frameCapacity: frames) else {
            throw AppFailure(message: "无法准备原唱分轨的音量缓冲区。")
        }
        let channels = Int(voice.format.channelCount)
        let pitchFramesPerWindow = Reference.mixBlockFrames / hop
        var vocalMeter = Array(repeating: VocalBalanceBand(sampleRate: Float(referenceSampleRate)), count: channels)
        var musicMeter = vocalMeter
        let scale = isolated ? 0 : gain
        var result: [Reference.MixLevel?] = []
        song.framePosition = 0
        backing.framePosition = 0
        while song.framePosition < song.length {
            try Task.checkCancellation()
            try song.read(into: voice)
            try backing.read(into: music)
            guard voice.frameLength > 0, voice.frameLength == music.frameLength else {
                throw AppFailure(message: "原唱与伴奏分轨的音量分析窗口不一致。")
            }
            var vocalPower: Float = 0, musicPower: Float = 0
            let count = Int(voice.frameLength)
            for channel in 0..<channels {
                let vocal = voice.floatChannelData![channel]
                let backing = music.floatChannelData![channel]
                for i in 0..<count {
                    let lead = vocalMeter[channel].filter(vocal[i] - backing[i] * scale)
                    let instrumental = musicMeter[channel].filter(backing[i] * gain)
                    vocalPower += lead * lead
                    musicPower += instrumental * instrumental
                }
            }
            let first = min(vocalLevels.count, result.count * pitchFramesPerWindow)
            let last = min(vocalLevels.count, first + pitchFramesPerWindow)
            let supported = vocalLevels[first..<last].compactMap { $0 }.count
            let minimum = Float(count * channels) * 0.000005
            if supported >= 4, musicPower > minimum, vocalPower > minimum {
                let vocalDB = 10 * log10f(vocalPower / Float(count * channels))
                let balanceDB = 10 * log10f(vocalPower / musicPower)
                result.append((-18...16).contains(balanceDB) ? Reference.MixLevel(vocalDB: vocalDB, balanceDB: balanceDB) : nil)
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// Measure decaying energy after phrase ends. Reject nearby notes and non-decaying tails.
    private static func estimateTail(events: [NoteEvent], levels: [Float]) -> (early: Float, late: Float)? {
        var tails: [Float] = [], lateTails: [Float] = []
        func median(_ window: Range<Int>) -> Float {
            let values = levels[window].sorted()
            return values[values.count / 2]
        }
        for (index, event) in events.enumerated() {
            let end = event.frames.upperBound
            guard event.frames.count >= 8, end + 19 <= levels.count else { continue }
            if index + 1 < events.count, events[index + 1].frames.lowerBound < end + 19 { continue }
            let lead = median(max(event.frames.lowerBound, end - 11)..<(end - 2))
            guard lead > -45 else { continue }
            let early = median((end + 2)..<(end + 8)) - lead
            let late = median((end + 10)..<(end + 19)) - lead
            if early <= -34, late <= -34 {
                tails.append(-34)
                lateTails.append(-45)
            } else if (-37 ... -8).contains(early), early - late >= 4 {
                tails.append(early)
                lateTails.append(max(-60, late))
            }
        }
        guard tails.count >= 4 else { return nil }
        tails.sort()
        lateTails.sort()
        return (tails[tails.count / 2], lateTails[lateTails.count / 2])
    }

    /// Look for a shared, short-lag copy of the lead after independently detected phrase endings.
    private static func estimateEcho(levels: [Float], read: (Int, Int) throws -> [Float]) throws -> Echo? {
        guard levels.count > 75 else { return nil }
        func median(_ window: Range<Int>) -> Float {
            let values = levels[window].sorted()
            return values[values.count / 2]
        }
        var endings: [Int] = []
        for i in 35..<(levels.count - 35) {
            let lead = median((i - 9)..<(i - 2))
            guard lead > -32, levels[i - 2] > lead - 5, levels[i] < lead - 5 else { continue }
            let early = median((i + 2)..<(i + 8))
            let late = median((i + 10)..<(i + 20))
            guard (8...28).contains(lead - early), early - late >= 4,
                  endings.last.map({ i - $0 >= 22 }) ?? true else { continue }
            endings.append(i)
        }
        guard endings.count >= 5 else { return nil }
        let selected = Array(stride(from: 0, to: endings.count, by: max(1, (endings.count + 31) / 32)))
        let sampleRate = Int(referenceSampleRate)
        let minimum = sampleRate * 60 / 1000
        let maximum = sampleRate * 600 / 1000
        let width = sampleRate * 60 / 1000
        let candidateLags = Array(stride(from: minimum, through: maximum, by: 2))
        var curves: [[Float]] = [], amplitudes: [[Float]] = []
        for index in selected {
            try Task.checkCancellation()
            let center = endings[index] * (hop / decimation) + sampleRate * 25 / 1000
            var samples = try read(center - maximum - 1, maximum + width + 1)
            // Pre-emphasis reduces the importance of coincidental matches in sustained fundamentals.
            for i in (1..<samples.count).reversed() { samples[i] -= 0.94 * samples[i - 1] }
            let measures = samples.withUnsafeBufferPointer { buffer -> ([Float], [Float]) in
                let base = buffer.baseAddress!
                let target = base + maximum + 1
                var targetPower: Float = 0
                vDSP_svesq(target, 1, &targetPower, vDSP_Length(width))
                var prefix = [Float](repeating: 0, count: samples.count + 1)
                for i in samples.indices { prefix[i + 1] = prefix[i] + samples[i] * samples[i] }
                var curve: [Float] = [], gains: [Float] = []
                for lag in candidateLags {
                    let start = maximum + 1 - lag
                    let power = max(1e-10, prefix[start + width] - prefix[start])
                    var dot: Float = 0
                    vDSP_dotpr(base + start, 1, target, 1, &dot, vDSP_Length(width))
                    curve.append(abs(dot) / sqrtf(max(1e-12, power * targetPower)))
                    gains.append(abs(dot) / power)
                }
                return (curve, gains)
            }
            curves.append(measures.0)
            amplitudes.append(measures.1)
        }
        let scores = candidateLags.indices.map { index -> Float in
            let values = curves.map { $0[index] }.sorted()
            return values[min(values.count - 1, Int(Float(values.count - 1) * 0.65 + 0.5))]
        }
        guard let winner = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let nearby = candidateLags.indices.filter { abs(candidateLags[$0] - candidateLags[winner]) >= sampleRate * 15 / 1000 }
        let rival = nearby.map { scores[$0] }.max() ?? 0
        let score = scores[winner]
        let clearPeak = score - rival >= 0.065
        let coherentCopy = score >= 0.92 && 1 - score * score <= 0.75 * (1 - rival * rival)
        guard score >= 0.34, clearPeak || coherentCopy else { return nil }
        let gains = curves.indices.compactMap { curves[$0][winner] >= 0.32 ? amplitudes[$0][winner] : nil }.sorted()
        guard gains.count >= max(3, (curves.count + 2) / 3) else { return nil }
        return Echo(seconds: Float(candidateLags[winner]) / Float(sampleRate),
                    gain: min(0.27, max(0.055, gains[gains.count / 2])))
    }

    static func render(from source: URL, to destination: URL, noiseDB: Float, reference: Reference?, applyPitch: Bool) throws -> Result {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(input.length)
        let block = rate * 6
        let context = hop * 13
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let samples = buffer.floatChannelData?[0] else {
            throw AppFailure(message: "无法准备修音缓冲区。")
        }
        var previousTail: [Float] = []
        var result = Result()
        for start in stride(from: 0, to: total, by: block) {
            try Task.checkCancellation()
            let end = min(total, start + block)
            let sourceStart = max(0, start - context)
            let sourceEnd = min(total, end + fade + context)
            input.framePosition = AVAudioFramePosition(sourceStart)
            let sourceCount = sourceEnd - sourceStart
            var original: [Float] = []
            original.reserveCapacity(sourceCount)
            while original.count < sourceCount {
                try Task.checkCancellation()
                let count = min(buffer.frameCapacity, AVAudioFrameCount(sourceCount - original.count))
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw AppFailure(message: "无法完整读取待修音的人声。") }
                original.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
            var corrected = original
            try tune(original, into: &corrected, minimumLevel: powf(10, max(-58, noiseDB + 8) / 20),
                     reference: reference, applyPitch: applyPitch, sourceStart: sourceStart, core: start..<end, result: &result)
            let offset = start - sourceStart
            for i in 0..<min(previousTail.count, end - start) {
                let mix = Float(i) / Float(previousTail.count)
                corrected[offset + i] = previousTail[i] * (1 - mix) + corrected[offset + i] * mix
            }
            previousTail = Array(corrected[(end - sourceStart)..<(min(end + fade, total) - sourceStart)])
            try corrected.withUnsafeBufferPointer { frames in
                for first in stride(from: offset, to: offset + end - start, by: Int(buffer.frameCapacity)) {
                    let count = min(Int(buffer.frameCapacity), offset + end - start - first)
                    buffer.frameLength = AVAudioFrameCount(count)
                    samples.update(from: frames.baseAddress! + first, count: count)
                    try output.write(from: buffer)
                }
            }
        }
        return result
    }

    private static func tune(_ original: [Float], into output: inout [Float], minimumLevel: Float,
                             reference: Reference?, applyPitch: Bool, sourceStart: Int, core: Range<Int>, result: inout Result) throws {
        var downsampled: [Float] = []
        downsampled.reserveCapacity(original.count / decimation)
        // Box average before decimation. YIN uses the low-frequency periodicity.
        for i in stride(from: 0, to: original.count - decimation + 1, by: decimation) {
            downsampled.append((original[i] + original[i + 1] + original[i + 2]
                                + original[i + 3] + original[i + 4] + original[i + 5]) / 6)
        }
        let pitches = try downsampled.withUnsafeBufferPointer { samples in
            var values: [Pitch] = []
            var difference = Array(repeating: Float(1), count: 124)
            for center in stride(from: 0, to: original.count, by: hop) {
                if values.count.isMultiple(of: 32) { try Task.checkCancellation() }
                values.append(estimatePitch(samples, center: center / decimation, minimumLevel: minimumLevel, scratch: &difference))
            }
            return values
        }
        var voiced: [NoteEvent] = []
        var first = 0
        while first < pitches.count {
            try Task.checkCancellation()
            guard pitches[first].hz > 0 else { first += 1; continue }
            var end = first + 1
            while end < pitches.count, pitches[end].hz > 0, abs(pitches[end].note - pitches[end - 1].note) < 0.42,
                  abs(pitches[end].note - pitches[first].note) < 0.72 {
                end += 1
            }
            if end - first >= 6 {
                voiced.append(event(frames: first..<end, values: pitches[first..<end].map(\.note)))
            }
            first = end
        }

        let origin = sourceStart / hop
        let referenceNotes = reference?.events.filter {
            $0.frames.upperBound >= origin - 8 && $0.frames.lowerBound < origin + pitches.count + 8
        } ?? []
        let guides = voiced.map { singer -> Match? in
            guard let candidate = bestMatch(singer, origin: origin, lag: 0, candidates: referenceNotes),
                  candidate.note == singer.note, candidate.coverage >= 0.69,
                  abs(candidate.lag) <= 6 else { return nil }
            return candidate
        }

        for (index, singer) in voiced.enumerated() {
            try Task.checkCancellation()
            guard singer.spread <= 0.53 else { continue }
            let first = singer.frames.lowerBound
            let end = singer.frames.upperBound
            let overlapStart = max(core.lowerBound, sourceStart + first * hop)
            let overlapEnd = min(core.upperBound, sourceStart + end * hop)
            let inCore = overlapEnd > overlapStart
            let prior = guides[..<index].compactMap { $0 }.last.flatMap {
                singer.midpoint - $0.singerMidpoint <= 100 ? $0 : nil
            }
            let next = guides[(index + 1)...].compactMap { $0 }.first.flatMap {
                $0.singerMidpoint - singer.midpoint <= 100 ? $0 : nil
            }
            let lag = prior.flatMap { before in
                next.flatMap { after in
                    abs(before.lag - after.lag) <= 5 ? Int(((before.lag + after.lag) * 0.5).rounded()) : nil
                }
            }
            let match = bestMatch(singer, origin: origin, lag: lag ?? 0, candidates: referenceNotes)
            if match != nil, inCore { result.comparedReference = true }

            let shift: Float
            var suspect: Int?
            if let match, match.note != singer.note {
                let distance = match.center - singer.center
                if singer.frames.count >= 7, match.coverage >= 0.66, abs(distance) >= 0.55 {
                    suspect = match.note
                }
                let closeInTime = abs(match.lag - Float(lag ?? 0)) <= 5
                let clearTiming = reference?.isIsolated == true && match.coverage >= 0.76 && closeInTime
                let guided = lag != nil && match.coverage >= 0.69
                let limit: Float = guided ? 2.25 : 1.55
                if suspect != nil, (clearTiming || guided), match.margin >= 0.17,
                   singer.spread <= 0.46, match.spread <= 0.38, abs(distance) <= limit {
                    shift = max(-1.83, min(1.83, distance * 0.91))
                } else {
                    shift = 0
                }
            } else if let match {
                let nominalDistance = Float(singer.note) - singer.center
                let distance = 0.30 * (match.center - singer.center) + 0.70 * nominalDistance
                if singer.frames.count >= 7, singer.spread <= 0.44, match.coverage >= 0.65,
                   match.spread <= 0.37, abs(distance) >= 0.13, abs(nominalDistance) >= 0.11,
                   distance * nominalDistance > 0 {
                    shift = max(-0.47, min(0.47, distance * 0.75))
                } else {
                    shift = 0
                }
            } else if reference == nil, singer.frames.count >= 15, singer.spread <= 0.22,
                      abs(Float(singer.note) - singer.center) >= 0.30 {
                shift = max(-0.12, min(0.12, (Float(singer.note) - singer.center) * 0.30))
            } else {
                shift = 0
            }
            var drift: [Float] = []
            if applyPitch, reference?.isIsolated == true, let match, match.coverage >= 0.69,
               end - first >= 11, match.note == singer.note || shift != 0 {
                // A broad local average targets slow drift. Fast oscillation and the note edges keep their movement.
                drift = (first..<end).map { frame in
                    let lower = max(first, frame - 6), upper = min(end - 1, frame + 6)
                    var mean: Float = 0, total: Float = 0
                    for nearby in lower...upper {
                        let distance = Float(nearby - frame)
                        let weight = expf(-distance * distance / 22)
                        mean += pitches[nearby].note * weight
                        total += weight
                    }
                    return min(0.26, max(-0.26, (singer.center - mean / total) * 0.52))
                }
                if (drift.map(abs).max() ?? 0) < 0.10 { drift = [] }
            }
            let applied = applyPitch && (shift != 0 || !drift.isEmpty)
                && synthesize(original, into: &output, pitches: pitches, first: first, end: end, shift: shift, drift: drift)
            if applied, inCore { result.adjustedSpans += 1 }
            if let suspect, inCore {
                result.append(Discrepancy(start: Double(overlapStart) / Double(rate), end: Double(overlapEnd) / Double(rate),
                                          sung: singer.note, target: suspect, corrected: applied))
            }
        }
    }

    private static func event(frames: Range<Int>, values: [Float]) -> NoteEvent {
        let sorted = values.sorted()
        return NoteEvent(frames: frames, center: sorted[sorted.count / 2],
                         spread: sorted[sorted.count * 4 / 5] - sorted[sorted.count / 5])
    }

    private static func referenceEvents(_ notes: [Float?]) -> [NoteEvent] {
        func stable(at position: Int) -> Float? {
            guard notes.indices.contains(position), let value = notes[position],
                  abs(value - value.rounded()) <= 0.43 else { return nil }
            return value
        }
        var events: [NoteEvent] = []
        var first = 0
        while first < notes.count {
            guard let initial = stable(at: first) else { first += 1; continue }
            var values = [initial]
            var end = first + 1
            while end < notes.count {
                if let value = stable(at: end), value.rounded() == initial.rounded() {
                    values.append(value)
                    end += 1
                } else if stable(at: end) == nil, let next = stable(at: end + 1), next.rounded() == initial.rounded() {
                    values.append(next)
                    end += 2
                } else {
                    break
                }
            }
            if values.count >= 5, Float(values.count) / Float(end - first) >= 0.78 {
                events.append(event(frames: first..<end, values: values))
            }
            first = end
        }
        return events
    }

    private struct Match {
        let note: Int
        let center: Float
        let spread: Float
        let coverage: Float
        let score: Float
        var margin: Float = 0
        let lag: Float
        let singerMidpoint: Float
    }

    private static func bestMatch(_ singer: NoteEvent, origin: Int, lag: Int, candidates: [NoteEvent]) -> Match? {
        let start = singer.frames.lowerBound + origin - lag
        let end = singer.frames.upperBound + origin - lag
        let midpoint = singer.midpoint + Float(origin)
        var best: Match?
        var runnerUp: Float = 0
        for event in candidates {
            if event.frames.upperBound < start { continue }
            if event.frames.lowerBound >= end { break }
            let intersection = max(0, min(end, event.frames.upperBound) - max(start, event.frames.lowerBound))
            let coverage = Float(intersection) / Float(singer.frames.count)
            guard coverage >= 0.54, event.spread <= 0.43 else { continue }
            let referenceCoverage = Float(intersection) / Float(event.frames.count)
            let alignedDistance = abs(midpoint - Float(lag) - event.midpoint)
            let timeScore = max(0, 1 - alignedDistance / 14)
            let octave = Int((Double(singer.note - event.note) / 12).rounded()) * 12
            let note = event.note + octave
            let same = note == singer.note
            let score = 0.62 * coverage + 0.17 * referenceCoverage + 0.16 * timeScore + (same ? 0.05 : 0)
            if score > (best?.score ?? 0) {
                runnerUp = best?.score ?? 0
                best = Match(note: note, center: event.center + Float(octave), spread: event.spread,
                             coverage: coverage, score: score, lag: midpoint - event.midpoint, singerMidpoint: singer.midpoint)
            } else {
                runnerUp = max(runnerUp, score)
            }
        }
        guard var best else { return nil }
        best.margin = best.score - runnerUp
        return best
    }

    private static func estimatePitch(_ samples: UnsafeBufferPointer<Float>, center: Int, minimumLevel: Float,
                                      scratch: inout [Float]) -> Pitch {
        let count = 224
        let start = center - count / 2
        let maxLag = scratch.count - 1
        guard start >= 0, start + count + maxLag <= samples.count, let base = samples.baseAddress else { return Pitch() }
        let a = base + start
        var energy: Float = 0
        vDSP_svesq(a, 1, &energy, vDSP_Length(count))
        guard energy >= minimumLevel * minimumLevel * Float(count) else { return Pitch() }
        var shiftedEnergy = energy
        var cumulative: Float = 0
        for lag in 1...maxLag {
            let added = a[count + lag - 1]
            let removed = a[lag - 1]
            shiftedEnergy += added * added - removed * removed
            var dot: Float = 0
            vDSP_dotpr(a, 1, a + lag, 1, &dot, vDSP_Length(count))
            let distance = max(0, energy + shiftedEnergy - 2 * dot)
            cumulative += distance
            scratch[lag] = cumulative > 0 ? distance * Float(lag) / cumulative : 1
        }
        var lag = 8
        while lag < maxLag - 1, scratch[lag] >= 0.17 { lag += 1 }
        guard scratch[lag] < 0.17 else { return Pitch() }
        while lag < maxLag - 1, scratch[lag + 1] < scratch[lag] { lag += 1 }
        let left = scratch[lag - 1], mid = scratch[lag], right = scratch[lag + 1]
        let curvature = left + right - 2 * mid
        let fraction = curvature > 0.00001 ? max(-0.5, min(0.5, (left - right) / (2 * curvature))) : 0
        let hz = Float(rate / decimation) / (Float(lag) + fraction)
        return Pitch(hz: hz, note: 69 + 12 * log2f(hz / 440))
    }

    /// Pitch-synchronous overlap-add with waveform matching at the source marks.
    private static func synthesize(_ source: [Float], into output: inout [Float], pitches: [Pitch],
                                   first: Int, end: Int, shift: Float, drift: [Float]) -> Bool {
        let startFrame = first * hop
        let endFrame = min(source.count, (end - 1) * hop)
        func period(at frame: Int) -> Float {
            let index = max(first, min(end - 1, (frame + hop / 2) / hop))
            return Float(rate) / pitches[index].hz
        }
        let seed = (startFrame..<min(endFrame, startFrame + Int(period(at: startFrame)))).max { source[$0] < source[$1] }
        guard let seed else { return false }
        var marks = [seed]
        while let mark = marks.last {
            let wavelength = Int(period(at: mark))
            let predicted = mark + wavelength
            let search = max(2, wavelength / 8)
            let width = wavelength / 4
            guard predicted + search + width < min(source.count, endFrame + wavelength), mark >= width else { break }
            var best = predicted
            var bestScore = -Float.infinity
            for candidate in (predicted - search)...(predicted + search) {
                var dot: Float = 0
                var energy: Float = 0
                for delta in stride(from: -width, through: width, by: 6) {
                    let sample = source[candidate + delta]
                    dot += source[mark + delta] * sample
                    energy += sample * sample
                }
                let score = dot / sqrtf(max(energy, 0.000001))
                if score > bestScore { best = candidate; bestScore = score }
            }
            marks.append(best)
        }
        guard marks.count >= 3, let last = marks.last else { return false }
        let finish = min(endFrame, last)
        let length = finish - seed
        guard length > 0 else { return false }
        var accumulated = Array(repeating: Float(0), count: length)
        var weights = accumulated
        var markIndex = 0
        var center = Float(seed)
        let rampFrames = max(1, min(rate / 30, length / 4))
        while Int(center.rounded()) < finish {
            let frame = Int(center.rounded())
            while markIndex + 1 < marks.count, abs(marks[markIndex + 1] - frame) < abs(marks[markIndex] - frame) {
                markIndex += 1
            }
            let mark = marks[markIndex]
            let leftPeriod = markIndex > 0 ? mark - marks[markIndex - 1] : marks[1] - mark
            let rightPeriod = markIndex + 1 < marks.count ? marks[markIndex + 1] - mark : leftPeriod
            let wavelength = Float(leftPeriod + rightPeriod) * 0.5
            let left = max(-leftPeriod, seed - frame, -mark)
            let right = min(rightPeriod, finish - 1 - frame, source.count - 1 - mark)
            for delta in left...right {
                let period = delta < 0 ? leftPeriod : rightPeriod
                let weight = (1 + cosf(.pi * Float(delta) / Float(period))) * 0.5
                let i = frame + delta - seed
                accumulated[i] += weight * source[mark + delta]
                weights[i] += weight
            }
            let edge = min(1, Float(min(frame - seed, finish - frame)) / Float(rampFrames))
            let eased = edge * edge * (3 - 2 * edge)
            var correction = shift
            if !drift.isEmpty {
                let position = min(Float(drift.count - 1), max(0, center / Float(hop) - Float(first)))
                let a = Int(position), b = min(drift.count - 1, a + 1)
                correction += drift[a] + (position - Float(a)) * (drift[b] - drift[a])
            }
            center += wavelength / powf(2, correction * eased / 12)
        }
        let transition = max(1, min(rate / 100, length / 4))
        for i in 0..<length where weights[i] > 0.01 {
            let phase = min(1, Float(min(i, length - 1 - i)) / Float(transition))
            let wet = phase * phase * (3 - 2 * phase)
            output[seed + i] = source[seed + i] * (1 - wet) + accumulated[i] / weights[i] * wet
        }
        return true
    }
}
