import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import os

struct AudioMeter {
    var peakDB: Float = -60
    var rmsDB: Float = -60
    var clipUntil: TimeInterval = 0
}

struct StageAudioMetrics: Sendable {
    var peakDB: Float = -60
    var rmsDB: Float = -60
    var clipUntil: TimeInterval = 0
    /// Normalized perceptual vocal energy in 0...1.
    var energy: Float = 0
    /// Normalized vocal spectral brightness in 0...1.
    var brightness: Float = 0.35
    /// Soft vowel viseme weights (summing to 1): open "啊" (A), round "噢/呜" (O), wide "咿/诶" (E).
    var vowelA: Float = 0.34
    var vowelO: Float = 0.33
    var vowelE: Float = 0.33
    /// Adaptive voice-activity gate for lip-sync (false during silence/room noise).
    var voiceActive: Bool = false
    /// Active lip-sync openness in 0...1 above the adaptive room noise floor.
    var voiceLevel: Float = 0
    /// Number of envelope samples written so far (monotonic counter).
    var ribbonTick: UInt64 = 0
}

struct MicTestLevel {
    var peakDB: Float = -60
    var nearClipping = false
}

/// One instance belongs to one audio graph, either live or offline.
final class VocalEffects {
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let reverb = AVAudioUnitReverb()
    var nodes: [AVAudioNode] { [eq, dynamics, reverb] }
    private let echo = AVAudioUnitDelay()
    private var currentSettings: VocalSettings?

    init() {
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 80
        eq.bands[0].bandwidth = 0.5
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 3200
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].bypass = false
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 260
        eq.bands[2].bandwidth = 1.2
        eq.bands[3].filterType = .highShelf
        eq.bands[3].frequency = 8000
        echo.lowPassCutoff = 4700
        update(VocalSettings())
    }

    func update(brightness: Float, compression: Float, space: Float) {
        update(VocalSettings(brightness: brightness, compression: compression, reverb: space))
    }

    func update(_ settings: VocalSettings) {
        let settings = settings.bounded
        guard settings != currentSettings else { return }
        let tuning = settings.tuning
        if currentSettings?.tuning.room != tuning.room {
            reverb.loadFactoryPreset(tuning.room.preset)
        }
        eq.bands[0].frequency = tuning.lowCut
        eq.bands[1].gain = settings.brightness
        eq.bands[2].gain = tuning.warmth
        eq.bands[2].bypass = tuning.warmth == 0
        eq.bands[3].gain = tuning.air
        eq.bands[3].bypass = tuning.air == 0
        if tuning.echoTimeMS != currentSettings?.tuning.echoTimeMS { echo.delayTime = Double(tuning.echoTimeMS) / 1000 }
        echo.feedback = tuning.echoFeedback
        echo.wetDryMix = tuning.echo
        echo.bypass = tuning.echo == 0
        reverb.wetDryMix = settings.reverb
        let unit = dynamics.audioUnit
        let compression = settings.compression
        let compressing = compression > 0.01
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, compressing ? -12 - compression * 16 : 0, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 12 - compression * 10, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, tuning.gateEnabled ? 3 : 1, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, tuning.gateThreshold, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, tuning.attackMS / 1000, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, tuning.releaseMS / 1000, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 0, 0)
        dynamics.bypass = !compressing && !tuning.gateEnabled
        currentSettings = settings
    }

    func applyReverbAfterStart() {
        guard let currentSettings else { return }
        // AVAudioEngine can initialize the reverb again when its render format is set.
        reverb.loadFactoryPreset(currentSettings.tuning.room.preset)
        reverb.wetDryMix = currentSettings.reverb
    }

    func connect(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode,
                 format: AVAudioFormat, includeReverb: Bool = true) {
        engine.attach(eq)
        engine.attach(dynamics)
        engine.attach(echo)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: dynamics, format: format)
        engine.connect(dynamics, to: echo, format: format)
        if includeReverb {
            engine.attach(reverb)
            engine.connect(echo, to: reverb, format: format)
            let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
            engine.connect(reverb, to: destination, format: stereo)
        } else {
            engine.connect(echo, to: destination, format: format)
        }
    }
}

extension VocalRoom {
    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .room: .mediumRoom
        case .plate: .plate
        case .hall: .largeHall
        }
    }
}

/// Zero-allocation 1024-point real FFT formant-band classifier separating open (A), round (O/U), and wide (E/I) vowels.
private final class VowelAnalyzer {
    private static let fftSize = 1024
    private static let log2n: vDSP_Length = 10
    private static let halfSize = 512

    private let fftSetup: FFTSetup?
    private var ring = Array(repeating: Float(0), count: fftSize)
    private var ringWrite = 0
    private var filled = 0
    private var framesSinceFFT = 0
    private var window = Array(repeating: Float(0), count: fftSize)
    private var windowed = Array(repeating: Float(0), count: fftSize)
    private var real = Array(repeating: Float(0), count: halfSize)
    private var imag = Array(repeating: Float(0), count: halfSize)
    private var power = Array(repeating: Float(0), count: halfSize)

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func reset() {
        for i in 0..<Self.fftSize { ring[i] = 0 }
        ringWrite = 0
        filled = 0
        framesSinceFFT = 0
    }

    /// Pushes new samples into the 1024-sample (~21ms) rolling window and returns stable window RMS plus
    /// FFT formant vowel weights at ~60Hz hop cadence (eliminates 5ms pitch-cycle ripple & twitching).
    func pushAndAnalyze(samples: UnsafePointer<Float>, count: Int, sampleRate: Float,
                        forceAnalyze: Bool = false) -> (windowRMS: Float, vowels: (a: Float, o: Float, e: Float)?) {
        if count >= Self.fftSize {
            let start = count - Self.fftSize
            for i in 0..<Self.fftSize { ring[i] = samples[start + i] }
            ringWrite = 0
            filled = Self.fftSize
        } else {
            for i in 0..<count {
                ring[ringWrite] = samples[i]
                ringWrite += 1
                if ringWrite == Self.fftSize { ringWrite = 0 }
            }
            filled = min(Self.fftSize, filled + count)
        }
        framesSinceFFT += count

        // Compute RMS over the full ~21ms rolling window so low vocal fundamentals never cause frame-to-frame ripple.
        let rmsCount = max(1, filled)
        var energySum: Float = 0
        for i in 0..<rmsCount {
            let s = ring[i]
            energySum += s * s
        }
        let windowRMS = sqrt(energySum / Float(rmsCount))

        let hopFrames = max(512, Int((sampleRate * 0.016).rounded()))
        guard filled >= Self.fftSize,
              (forceAnalyze || framesSinceFFT >= hopFrames),
              windowRMS > 0.012,
              sampleRate > 0,
              let fftSetup else {
            return (windowRMS, nil)
        }
        framesSinceFFT = 0

        let tail = Self.fftSize - ringWrite
        for i in 0..<tail { windowed[i] = ring[ringWrite + i] * window[i] }
        for i in 0..<ringWrite { windowed[tail + i] = ring[i] * window[tail + i] }

        for k in 0..<Self.halfSize {
            real[k] = windowed[2 * k]
            imag[k] = windowed[2 * k + 1]
        }
        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.halfSize))
            }
        }

        let binHz = sampleRate / Float(Self.fftSize)
        func bandDB(_ lowHz: Float, _ highHz: Float) -> Float {
            let lo = max(1, Int((lowHz / binHz).rounded(.down)))
            let hi = min(Self.halfSize - 1, Int((highHz / binHz).rounded(.up)))
            guard lo <= hi else { return -90 }
            var sum: Float = 0
            var peak: Float = 0
            for k in lo...hi {
                let p = power[k]
                sum += p
                if p > peak { peak = p }
            }
            let mean = sum / Float(hi - lo + 1)
            let envelope = mean * 0.35 + peak * 0.65
            return 10 * log10(max(envelope, 1e-12))
        }

        // Formant regions:
        // O/U ("噢/呜"): concentrated in 180–740 Hz with steep roll-off above 800 Hz.
        // A   ("啊")   : open vocal tract surges in 820–1650 Hz (F1+F2 resonance).
        // E/I ("咿/诶"): low F1 + deep valley in 820–1650 Hz + strong F2/F3 rebound in 1850–4200 Hz.
        let dbO = bandDB(180, 740)
        let dbA = bandDB(820, 1650)
        let dbE = bandDB(1850, 4200)
        let dbSib = bandDB(4200, 7800)

        // Compensate glottal tilt AND detect the signature "咿/诶" F2 rebound above the A-band valley
        // (immune to close-mic bass proximity boost in dbO, while ignoring noise-floor flatness in pure "呜").
        let ePeak = max(dbE, dbSib - 1.5)
        let flooredA = max(dbA, dbO - 26.0)
        let eRebound = max(0, (ePeak - flooredA) + 4.5)

        let scoreO = dbO
        let scoreA = dbA + 10.0
        let scoreE = ePeak + 18.5 + eRebound * 1.1

        let temperature: Float = 3.3
        let maxScore = max(scoreO, max(scoreA, scoreE))
        let eA = exp((scoreA - maxScore) / temperature)
        let eO = exp((scoreO - maxScore) / temperature)
        let eE = exp((scoreE - maxScore) / temperature)
        let total = max(1e-6, eA + eO + eE)
        return (windowRMS, (a: eA / total, o: eO / total, e: eE / total))
    }
}

private let stageRenderNotify: AURenderCallback = { inRefCon, ioActionFlags, _, inBusNumber, inNumberFrames, ioData in
    guard ioActionFlags.pointee.contains(.unitRenderAction_PostRender),
          inBusNumber == 0,
          inNumberFrames > 0 else { return noErr }
    let bridge = Unmanaged<CaptureBridge>.fromOpaque(inRefCon).takeUnretainedValue()
    if ioActionFlags.pointee.contains(.unitRenderAction_OutputIsSilence) {
        bridge.receiveRealtimeSilence(frameCount: Int(inNumberFrames))
        return noErr
    }
    guard let ioData else { return noErr }
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
    guard let first = bufferList.first,
          let raw = first.mData,
          Int(first.mDataByteSize) >= Int(inNumberFrames) * MemoryLayout<Float>.size else { return noErr }
    bridge.receiveRealtimeVisual(samples: raw.assumingMemoryBound(to: Float.self), frameCount: Int(inNumberFrames))
    return noErr
}

final class CaptureBridge: @unchecked Sendable {
    static let ribbonLength = 64

    private struct State {
        var meter = AudioMeter()
        var writer: RecordingWriter?
        var testLevel: MicTestLevel?
        var energy: Float = 0
        var brightness: Float = 0.35
        var vowelA: Float = 0.34
        var vowelO: Float = 0.33
        var vowelE: Float = 0.33
        var noiseFloorDB: Float = -46
        var voiceActive = false
        var voiceHangoverFrames = 0
        var voiceLevel: Float = 0
        var realtimeVisualActive = false
        var realtimeSampleRate: Float = 48_000
        var ribbon = Array(repeating: Float(0), count: CaptureBridge.ribbonLength)
        var ribbonIndex = 0
        var ribbonTick: UInt64 = 0
        var accumulatedFrames = 0
        var accumulatedEnergy: Float = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let vowelLock = OSAllocatedUnfairLock(initialState: VowelAnalyzer())
    var meter: AudioMeter { state.withLock { $0.meter } }
    var stageMetrics: StageAudioMetrics {
        state.withLock {
            StageAudioMetrics(peakDB: $0.meter.peakDB, rmsDB: $0.meter.rmsDB, clipUntil: $0.meter.clipUntil,
                              energy: $0.energy, brightness: $0.brightness,
                              vowelA: $0.vowelA, vowelO: $0.vowelO, vowelE: $0.vowelE,
                              voiceActive: $0.voiceActive, voiceLevel: $0.voiceLevel,
                              ribbonTick: $0.ribbonTick)
        }
    }
    var writer: RecordingWriter? {
        get { state.withLock { $0.writer } }
        set { state.withLock { $0.writer = newValue } }
    }

    /// Copies the rolling vocal energy history into a caller-owned buffer without audio-thread allocations.
    func copyStageSignal(into destination: inout [Float]) -> StageAudioMetrics {
        if destination.count != Self.ribbonLength {
            destination = Array(repeating: 0, count: Self.ribbonLength)
        }
        return state.withLockUnchecked { state in
            let count = Self.ribbonLength
            let head = state.ribbonIndex
            for i in 0..<count {
                destination[i] = state.ribbon[(head + i) % count]
            }
            return StageAudioMetrics(peakDB: state.meter.peakDB, rmsDB: state.meter.rmsDB,
                                     clipUntil: state.meter.clipUntil, energy: state.energy,
                                     brightness: state.brightness,
                                     vowelA: state.vowelA, vowelO: state.vowelO, vowelE: state.vowelE,
                                     voiceActive: state.voiceActive, voiceLevel: state.voiceLevel,
                                     ribbonTick: state.ribbonTick)
        }
    }

    func configureRealtimeVisual(sampleRate: Float) {
        state.withLock { state in
            state.realtimeSampleRate = sampleRate > 0 ? sampleRate : 48_000
            state.realtimeVisualActive = true
        }
    }

    func installRealtimeVisualProbe(on node: AVAudioUnit, sampleRate: Double) -> AudioUnit? {
        let unit = node.audioUnit
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        guard AudioUnitAddRenderNotify(unit, stageRenderNotify, refCon) == noErr else { return nil }
        configureRealtimeVisual(sampleRate: Float(sampleRate))
        return unit
    }

    func removeRealtimeVisualProbe(from unit: AudioUnit) {
        AudioUnitRemoveRenderNotify(unit, stageRenderNotify, Unmanaged.passUnretained(self).toOpaque())
    }

    func resetStageSignal() {
        vowelLock.withLockUnchecked { $0.reset() }
        state.withLock { state in
            state.meter = AudioMeter()
            state.energy = 0
            state.brightness = 0.35
            state.vowelA = 0.34
            state.vowelO = 0.33
            state.vowelE = 0.33
            state.noiseFloorDB = -46
            state.voiceActive = false
            state.voiceHangoverFrames = 0
            state.voiceLevel = 0
            state.realtimeVisualActive = false
            for i in 0..<state.ribbon.count { state.ribbon[i] = 0 }
            state.ribbonIndex = 0
            state.accumulatedFrames = 0
            state.accumulatedEnergy = 0
        }
    }

    func beginMicTest(_ writer: RecordingWriter) {
        state.withLock { $0.writer = writer; $0.testLevel = MicTestLevel() }
    }

    func endMicTest() -> MicTestLevel {
        state.withLock {
            let result = $0.testLevel ?? MicTestLevel()
            $0.writer = nil
            $0.testLevel = nil
            return result
        }
    }

    /// Hardware IO render-rate visual telemetry (~5-10ms latency instead of AVAudioNode tap's ~100ms chunks).
    func receiveRealtimeVisual(samples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let sampleRate = state.withLock { $0.realtimeSampleRate }
        updateVisualMetrics(samples: samples, frameCount: frameCount, sampleRate: sampleRate, fromTap: false)
    }

    func receiveRealtimeSilence(frameCount: Int) {
        let sampleRate = state.withLock { $0.realtimeSampleRate }
        let stepFrames = max(512, Int((sampleRate * 0.020).rounded()))
        state.withLock { state in
            state.meter.peakDB = -60
            state.meter.rmsDB = -60
            state.energy = 0
            state.voiceActive = false
            state.voiceHangoverFrames = 0
            state.voiceLevel = 0
            state.brightness = state.brightness * 0.92 + 0.35 * 0.08
            state.accumulatedFrames += frameCount
            if state.accumulatedFrames >= stepFrames {
                state.ribbon[state.ribbonIndex] = state.accumulatedEnergy
                state.ribbonIndex = (state.ribbonIndex + 1) % Self.ribbonLength
                state.ribbonTick &+= 1
                state.accumulatedFrames = 0
                state.accumulatedEnergy = 0
            }
        }
    }

    private func updateVisualMetrics(samples: UnsafePointer<Float>, frameCount: Int, sampleRate: Float, fromTap: Bool) {
        var peak: Float = 0
        var energy: Float = 0
        var diffEnergy: Float = 0
        var previous = samples[0]
        for i in 0..<frameCount {
            let sample = samples[i]
            peak = max(peak, abs(sample))
            energy += sample * sample
            let delta = sample - previous
            diffEnergy += delta * delta
            previous = sample
        }
        let chunkRMS = sqrt(energy / Float(frameCount))
        let measuredPeak = peak
        let peakDB = max(-60, 20 * log10(max(measuredPeak, 0.000001)))
        let analysis = vowelLock.withLockUnchecked {
            $0.pushAndAnalyze(samples: samples, count: frameCount, sampleRate: sampleRate, forceAnalyze: fromTap)
        }
        // Use the ~21ms rolling window RMS for steady, ripple-free level & lip-sync gating.
        let stableRMS = fromTap ? chunkRMS : analysis.windowRMS
        let rmsDB = max(-60, 20 * log10(max(stableRMS, 0.000001)))
        let normalizedEnergy = min(1, max(0, (rmsDB + 52) / 46))
        let measuredBrightness: Float?
        if stableRMS > 0.004, energy > 1e-10 {
            let ratio = sqrt(diffEnergy / energy)
            let freqApprox = max(120, min(3200, (ratio / (2 * .pi)) * sampleRate))
            let lowLog = log2(Float(120))
            let highLog = log2(Float(2800))
            measuredBrightness = min(1, max(0, (log2(freqApprox) - lowLog) / (highLog - lowLog)))
        } else {
            measuredBrightness = nil
        }
        let stepFrames = max(512, Int((sampleRate * 0.020).rounded()))
        let hangoverLimit = max(512, Int((sampleRate * 0.055).rounded()))
        let dtSeconds = Float(frameCount) / max(8000, sampleRate)
        state.withLock { state in
            state.meter.peakDB = peakDB
            state.meter.rmsDB = rmsDB
            if measuredPeak >= 0.99 { state.meter.clipUntil = ProcessInfo.processInfo.systemUptime + 1.5 }
            state.energy = normalizedEnergy

            // Adaptive room noise floor + hysteresis gate so ambient mic noise never moves the mouth.
            if rmsDB < state.noiseFloorDB {
                let fall = min(1, dtSeconds * 3.5)
                state.noiseFloorDB += (rmsDB - state.noiseFloorDB) * fall
            } else if !state.voiceActive && rmsDB < state.noiseFloorDB + 5.5 && rmsDB < -28 {
                let rise = min(1, dtSeconds * 0.45)
                state.noiseFloorDB += (rmsDB - state.noiseFloorDB) * rise
            }
            state.noiseFloorDB = min(-28, max(-54, state.noiseFloorDB))

            let openThreshold = max(-34.0, state.noiseFloorDB + 8.0)
            let closeThreshold = max(-38.0, state.noiseFloorDB + 4.5)
            if state.voiceActive {
                if rmsDB >= closeThreshold {
                    state.voiceHangoverFrames = hangoverLimit
                } else {
                    state.voiceHangoverFrames -= frameCount
                    if state.voiceHangoverFrames <= 0 {
                        state.voiceActive = false
                        state.voiceHangoverFrames = 0
                    }
                }
            } else if rmsDB >= openThreshold {
                state.voiceActive = true
                state.voiceHangoverFrames = hangoverLimit
            }

            if state.voiceActive {
                let floor = closeThreshold
                let span = max(14.0, -7.0 - floor)
                let linear = min(1, max(0, (rmsDB - floor) / span))
                state.voiceLevel = pow(linear, 0.88)
            } else {
                state.voiceLevel = 0
            }

            if let measuredBrightness {
                state.brightness = state.brightness * 0.65 + measuredBrightness * 0.35
            } else {
                state.brightness = state.brightness * 0.92 + 0.35 * 0.08
            }
            if state.voiceActive, let vowels = analysis.vowels {
                // Smooth 60Hz hop EMA: reaches ~85% in ~50ms with zero frame-to-frame twitching.
                state.vowelA = state.vowelA * 0.62 + vowels.a * 0.38
                state.vowelO = state.vowelO * 0.62 + vowels.o * 0.38
                state.vowelE = state.vowelE * 0.62 + vowels.e * 0.38
            }
            state.accumulatedFrames += frameCount
            state.accumulatedEnergy = max(state.accumulatedEnergy, normalizedEnergy)
            if state.accumulatedFrames >= stepFrames {
                state.ribbon[state.ribbonIndex] = state.accumulatedEnergy
                state.ribbonIndex = (state.ribbonIndex + 1) % Self.ribbonLength
                state.ribbonTick &+= 1
                state.accumulatedFrames = 0
                state.accumulatedEnergy = 0
            }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let realtimeActive = state.withLock { $0.realtimeVisualActive }
        if !realtimeActive {
            let sampleRate = Float(buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 48_000)
            updateVisualMetrics(samples: samples, frameCount: frameCount, sampleRate: sampleRate, fromTap: true)
        }
        var peak: Float = 0
        for i in 0..<frameCount { peak = max(peak, abs(samples[i])) }
        let measuredPeak = peak
        let peakDB = max(-60, 20 * log10(max(measuredPeak, 0.000001)))
        let writer = state.withLock { state -> RecordingWriter? in
            if measuredPeak >= 0.99 { state.meter.clipUntil = ProcessInfo.processInfo.systemUptime + 1.5 }
            if var level = state.testLevel {
                level.peakDB = max(level.peakDB, peakDB)
                level.nearClipping = level.nearClipping || measuredPeak >= 0.99
                state.testLevel = level
            }
            return state.writer
        }
        writer?.append(buffer, at: time)
    }
}

@MainActor
final class AudioEngine {
    private(set) var engine: AVAudioEngine?
    private(set) var captureFormat: AVAudioFormat?
    let bridge = CaptureBridge()
    private var captureMixer: AVAudioMixerNode?
    private var renderNotifyUnit: AudioUnit?
    private var monitorMixer: AVAudioMixerNode?
    private var effects: VocalEffects?
    private var configurationObserver: NSObjectProtocol?
    var configurationChanged: (() -> Void)?
    private(set) var deviceDescription = "麦克风未启用"
    private(set) var bufferDescription = ""
    var isRunning: Bool { engine?.isRunning == true }

    func start(input: AudioDevice, output: AudioDevice, channel: Int) throws {
        stop()
        guard channel >= 0, channel < input.inputChannels else { throw AppFailure(message: "请选择有效的麦克风输入通道。") }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let outputNode = engine.outputNode
        try Self.selectDevice(input.id, node: inputNode)
        try Self.selectDevice(output.id, node: outputNode)
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1) else {
            throw AppFailure(message: "麦克风没有可用音频格式，请重新连接或选择设备。")
        }

        let capture = AVAudioMixerNode()
        // Zero-band pass-through AVAudioUnit exposes a render-notify AudioUnit at hardware IO cadence (~5-10ms).
        let visualProbe = AVAudioUnitEQ(numberOfBands: 0)
        let monitor = AVAudioMixerNode()
        let effects = VocalEffects()
        engine.attach(capture)
        engine.attach(visualProbe)
        engine.attach(monitor)

        engine.connect(inputNode, to: capture, format: mono)
        // AUHAL maps the selected physical channel into our single-channel processing stream.
        guard let ioUnit = inputNode.audioUnit else { throw AppFailure(message: "无法访问声卡输入。") }
        var mapping = Int32(channel)
        let mapStatus = AudioUnitSetProperty(ioUnit, kAudioOutputUnitProperty_ChannelMap,
                                            kAudioUnitScope_Output, 1, &mapping, UInt32(MemoryLayout<Int32>.size))
        guard mapStatus == noErr else { throw AppFailure(message: "此设备不支持选择单声道输入（\(mapStatus)），请尝试其他输入设备。") }
        engine.connect(capture, to: visualProbe, format: mono)
        effects.connect(in: engine, from: visualProbe, to: monitor, format: mono)
        // Apple's plate reverb outputs stereo, including when its input is mono.
        let stereo = AVAudioFormat(standardFormatWithSampleRate: mono.sampleRate, channels: 2)!
        // Gate after all effects: turning monitoring off also silences the reverb tail.
        engine.connect(monitor, to: engine.mainMixerNode, format: stereo)
        monitor.outputVolume = 0
        engine.mainMixerNode.outputVolume = 0.85

        let bridge = self.bridge
        capture.installTap(onBus: 0, bufferSize: 512, format: mono) { buffer, time in
            bridge.receive(buffer, time: time)
        }
        var installedNotifyUnit: AudioUnit?
        let probeUnit = visualProbe.audioUnit
        let refCon = Unmanaged.passUnretained(bridge).toOpaque()
        if AudioUnitAddRenderNotify(probeUnit, stageRenderNotify, refCon) == noErr {
            installedNotifyUnit = probeUnit
            bridge.configureRealtimeVisual(sampleRate: Float(mono.sampleRate))
        }
        engine.prepare()
        do { try engine.start() } catch {
            if let unit = installedNotifyUnit {
                AudioUnitRemoveRenderNotify(unit, stageRenderNotify, Unmanaged.passUnretained(bridge).toOpaque())
                bridge.resetStageSignal()
            }
            capture.removeTap(onBus: 0)
            throw error
        }
        effects.applyReverbAfterStart()
        self.engine = engine
        self.captureFormat = mono
        self.captureMixer = capture
        self.renderNotifyUnit = installedNotifyUnit
        self.monitorMixer = monitor
        self.effects = effects
        deviceDescription = "\(Int(mono.sampleRate)) Hz · 单声道 · 24-bit WAV"
        bufferDescription = Self.bufferFrames(input.id).map { "设备缓冲 \($0) 帧" } ?? "设备缓冲由系统管理"
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged?() }
        }
    }

    static func selectDevice(_ id: AudioDeviceID, node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw AppFailure(message: "无法初始化音频设备。") }
        var deviceID = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AppFailure(message: "无法打开音频设备（\(status)）。请确认设备已连接且未被独占。") }
    }

    func update(monitoring: Bool, settings: VocalSettings) {
        effects?.update(settings)
        monitorMixer?.outputVolume = monitoring ? settings.gain : 0
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let unit = renderNotifyUnit {
            AudioUnitRemoveRenderNotify(unit, stageRenderNotify, Unmanaged.passUnretained(bridge).toOpaque())
            renderNotifyUnit = nil
        }
        captureMixer?.removeTap(onBus: 0)
        captureMixer = nil
        bridge.writer = nil
        bridge.resetStageSignal()
        engine?.stop()
        engine = nil
        captureFormat = nil
        monitorMixer = nil
        effects = nil
    }

    private static func bufferFrames(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames) == noErr ? frames : nil
    }
}
