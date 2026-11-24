import AVFoundation
import AudioToolbox
import CoreAudio
import os

struct AudioMeter {
    var peakDB: Float = -60
    var rmsDB: Float = -60
    var clipUntil: TimeInterval = 0
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

final class CaptureBridge: @unchecked Sendable {
    private struct State {
        var meter = AudioMeter()
        var writer: RecordingWriter?
        var testLevel: MicTestLevel?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var meter: AudioMeter { state.withLock { $0.meter } }
    var writer: RecordingWriter? {
        get { state.withLock { $0.writer } }
        set { state.withLock { $0.writer = newValue } }
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

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        var energy: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[i]))
            energy += samples[i] * samples[i]
        }
        let rms = sqrt(energy / Float(buffer.frameLength))
        let measuredPeak = peak
        let writer = state.withLock { state -> RecordingWriter? in
            state.meter.peakDB = max(-60, 20 * log10(max(measuredPeak, 0.000001)))
            state.meter.rmsDB = max(-60, 20 * log10(max(rms, 0.000001)))
            if measuredPeak >= 0.99 { state.meter.clipUntil = ProcessInfo.processInfo.systemUptime + 1.5 }
            if var level = state.testLevel {
                level.peakDB = max(level.peakDB, state.meter.peakDB)
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
        let monitor = AVAudioMixerNode()
        let effects = VocalEffects()
        engine.attach(capture)
        engine.attach(monitor)

        engine.connect(inputNode, to: capture, format: mono)
        // AUHAL maps the selected physical channel into our single-channel processing stream.
        guard let ioUnit = inputNode.audioUnit else { throw AppFailure(message: "无法访问声卡输入。") }
        var mapping = Int32(channel)
        let mapStatus = AudioUnitSetProperty(ioUnit, kAudioOutputUnitProperty_ChannelMap,
                                            kAudioUnitScope_Output, 1, &mapping, UInt32(MemoryLayout<Int32>.size))
        guard mapStatus == noErr else { throw AppFailure(message: "此设备不支持选择单声道输入（\(mapStatus)），请尝试其他输入设备。") }
        effects.connect(in: engine, from: capture, to: monitor, format: mono)
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
        engine.prepare()
        do { try engine.start() } catch {
            capture.removeTap(onBus: 0)
            throw error
        }
        effects.applyReverbAfterStart()
        self.engine = engine
        self.captureFormat = mono
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
        bridge.writer = nil
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
