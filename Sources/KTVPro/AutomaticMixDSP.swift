import Accelerate
import AVFoundation
import Foundation

enum AutomaticMixDSP {
    static let rate = 48_000

    static func amplitude(_ db: Float) -> Float { powf(10, db / 20) }
    static func powerDB(_ power: Float) -> Float { 10 * log10f(max(1e-10, power)) }
    static func smooth(_ value: Float) -> Float {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    struct Envelope {
        private(set) var value: Float = 0
        private let attack: Float
        private let release: Float

        init(attack: Float, release: Float, rate: Float = Float(AutomaticMixDSP.rate)) {
            self.attack = 1 - expf(-1 / (rate * attack))
            self.release = 1 - expf(-1 / (rate * release))
        }

        mutating func track(_ sample: Float) -> Float {
            value += (sample > value ? attack : release) * (sample - value)
            return value
        }
    }

    struct Filter {
        private let b0, b1, b2, a1, a2: Float
        private var z1: Float = 0, z2: Float = 0

        private init(_ b0: Float, _ b1: Float, _ b2: Float, _ a0: Float, _ a1: Float, _ a2: Float) {
            self.b0 = b0 / a0
            self.b1 = b1 / a0
            self.b2 = b2 / a0
            self.a1 = a1 / a0
            self.a2 = a2 / a0
        }

        static func band(_ hz: Float, q: Float) -> Self {
            let w = 2 * Float.pi * hz / Float(rate)
            let alpha = sinf(w) / (2 * q)
            return Self(alpha, 0, -alpha, 1 + alpha, -2 * cosf(w), 1 - alpha)
        }

        static func highPass(_ hz: Float) -> Self { pass(hz, high: true) }
        static func lowPass(_ hz: Float) -> Self { pass(hz, high: false) }

        private static func pass(_ hz: Float, high: Bool) -> Self {
            let w = 2 * Float.pi * hz / Float(rate)
            let cosine = cosf(w)
            let alpha = sinf(w) * 0.70710678
            let middle = high ? -(1 + cosine) : 1 - cosine
            let edge = abs(middle) / 2
            return Self(edge, middle, edge, 1 + alpha, -2 * cosine, 1 - alpha)
        }

        static func bell(_ hz: Float, q: Float, db: Float) -> Self {
            let w = 2 * Float.pi * hz / Float(rate)
            let a = amplitude(db / 2)
            let alpha = sinf(w) / (2 * q)
            let middle = -2 * cosf(w)
            return Self(1 + alpha * a, middle, 1 - alpha * a, 1 + alpha / a, middle, 1 - alpha / a)
        }

        static func shelf(_ hz: Float, db: Float, slope: Float) -> Self {
            let w = 2 * Float.pi * hz / Float(rate)
            let a = amplitude(db / 2)
            let cosine = cosf(w)
            let t = sqrtf(a) * sinf(w) * sqrtf((a + 1 / a) * (1 / slope - 1) + 2)
            let sum = a + 1, difference = a - 1
            return Self(a * (sum + difference * cosine + t),
                        -2 * a * (difference + sum * cosine),
                        a * (sum + difference * cosine - t),
                        sum - difference * cosine + t,
                        2 * (difference - sum * cosine),
                        sum - difference * cosine - t)
        }

        mutating func process(_ sample: Float) -> Float {
            let output = b0 * sample + z1
            z1 = b1 * sample - a1 * output + z2
            z2 = b2 * sample - a2 * output
            return output
        }
    }

    struct Saturation {
        private var previous: Float = 0
        private var inHighPass = Filter.highPass(145)
        private var inLowPass = Filter.lowPass(11000)
        private var outHighPass = Filter.highPass(115)
        private static let bias: Float = 0.085
        private static let drive: Float = 2.65
        private static let biasOutput = tanhf(drive * bias)
        private static let slope = 1 - biasOutput * biasOutput

        mutating func process(_ sample: Float) -> Float {
            let input = inLowPass.process(inHighPass.process(sample))
            // Interpolate four evaluations and average only the added harmonics.
            var added: Float = 0
            for index in 1...4 {
                let x = previous + (input - previous) * (Float(index) * 0.25)
                let gentle = (tanhf(Self.drive * (x + Self.bias)) - Self.biasOutput) / (Self.drive * Self.slope)
                let symmetrical = tanhf(Self.drive * x) / Self.drive
                added += 0.25 * (gentle - x) + 0.065 * (symmetrical - x)
            }
            previous = input
            return sample + outHighPass.process(added * 0.25)
        }
    }

    struct Tempo {
        private static let size = 512
        private let fft: FFT
        private var window = Array(repeating: Float(0), count: size)
        private var ring = Array(repeating: Float(0), count: size)
        private var spectrum = Spectrum(size)
        private var previous = Array(repeating: Float(0), count: size / 2)
        private var position = 0, samples = 0, decimation = 0
        private var sum: Float = 0
        private var flux: [Float] = []

        init() throws {
            fft = try FFT(size: Self.size)
            vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        }

        mutating func add(_ mono: Float) {
            sum += mono
            decimation += 1
            guard decimation == 6 else { return }
            ring[position] = sum / 6
            position = (position + 1) % Self.size
            sum = 0
            decimation = 0
            samples += 1
            guard samples >= Self.size, samples.isMultiple(of: 80) else { return }
            spectrum.load(count: Self.size) { ring[(position + $0) % Self.size] * window[$0] }
            fft.forward(&spectrum)
            var onset: Float = 0
            for bin in 2..<(Self.size / 2) {
                let magnitude = log1pf(1.5 * hypotf(spectrum.real[bin], spectrum.imaginary[bin]))
                onset += max(0, magnitude - previous[bin])
                previous[bin] = magnitude
            }
            flux.append(onset)
        }

        func beatSeconds() -> Float? {
            guard flux.count >= 1000 else { return nil }
            let mean = flux.reduce(0, +) / Float(flux.count)
            let values = flux.map { $0 - mean }
            let total = values.reduce(Float(0)) { $0 + $1 * $1 }
            guard total > 0.001 else { return nil }
            var correlation = Array(repeating: Float(0), count: 302)
            values.withUnsafeBufferPointer { data in
                for lag in 34..<correlation.count {
                    var dot: Float = 0
                    vDSP_dotpr(data.baseAddress!, 1, data.baseAddress! + lag, 1, &dot,
                               vDSP_Length(values.count - lag))
                    correlation[lag] = dot / total
                }
            }
            func score(_ lag: Int) -> Float {
                correlation[lag] + 0.45 * correlation[2 * lag] + 0.16 * correlation[3 * lag]
                    - (lag > 85 ? 0.016 : 0)
            }
            let candidates = (36...100).filter { correlation[$0] >= correlation[$0-1] && correlation[$0] >= correlation[$0+1] }
            guard let strongest = candidates.max(by: { score($0) < score($1) }),
                  correlation[strongest] > 0.10, score(strongest) > 0.19 else { return nil }
            // A strong downbeat can make a two-beat lag win. Prefer the shorter
            // pulse only when it also has direct onset support.
            let half = candidates.filter {
                abs(2 * $0 - strongest) <= 2
                    && correlation[$0] >= 0.75 * correlation[strongest] && score($0) >= 0.74 * score(strongest)
            }.max { score($0) < score($1) }
            let best = half ?? strongest
            let before = correlation[best - 1], peak = correlation[best], after = correlation[best + 1]
            let curve = 2 * peak - before - after
            let refinement = curve > 0.0001 ? min(0.5, max(-0.5, (after - before) / (2 * curve))) : 0
            return (Float(best) + refinement) * 0.01
        }
    }

    struct Space {
        private let delayFrames: Int
        private var echo, double: DelayLine
        private var echoHigh = Filter.highPass(365)
        private var echoLow = Filter.lowPass(4080)
        private var doubleHigh = Filter.highPass(690)
        private var doubleLow = Filter.lowPass(6900)
        private var left = Detune(cents: 6, milliseconds: 9.4)
        private var right = Detune(cents: -6, milliseconds: 23.7)
        private var activity = Envelope(attack: 0.025, release: 0.09)

        init(delaySeconds: Float) {
            delayFrames = Int(Float(rate) * delaySeconds)
            echo = DelayLine(length: 3 * delayFrames + 2)
            double = DelayLine(length: Int(0.035 * Double(rate)))
        }

        mutating func process(_ voice: Float, typical: Float) -> (echo: SIMD2<Float>, double: SIMD2<Float>, openness: Float) {
            let presence = smooth((activity.track(abs(voice)) / max(0.015, typical) - 0.22) / 0.75)
            let openness = 1 - presence
            echo.push(echoLow.process(echoHigh.process(voice)))
            let first = echo.tap(delayFrames), second = 0.17 * echo.tap(2 * delayFrames)
            let third = (0.17 * 0.17) * echo.tap(3 * delayFrames)
            let delay = SIMD2(first + 0.34 * second + third, 0.69 * first + second + 0.3 * third) * (1 - 0.35 * presence)
            double.push(doubleLow.process(doubleHigh.process(voice)))
            let spread = SIMD2(left.process(double), right.process(double))
            return (delay, width(spread, 0.82), openness)
        }
    }

    static func width(_ signal: SIMD2<Float>, _ amount: Float) -> SIMD2<Float> {
        let center = (signal.x + signal.y) * 0.5
        return SIMD2(repeating: center) + amount * (signal - SIMD2(repeating: center))
    }

    private struct DelayLine {
        private var samples: [Float]
        private var head = 0

        init(length: Int) { samples = Array(repeating: 0, count: length) }

        mutating func push(_ value: Float) {
            head += 1
            if head == samples.count { head = 0 }
            samples[head] = value
        }

        func tap(_ delay: Int) -> Float {
            let index = head - delay
            return samples[index >= 0 ? index : index + samples.count]
        }

        func fractional(_ delay: Float) -> Float {
            let index = Int(delay)
            let first = tap(index)
            return first + (tap(index + 1) - first) * (delay - Float(index))
        }
    }

    private struct Detune {
        private let delay: Float
        private let step: Float
        private static let sweep = 0.009 * Float(rate)
        private var phase: Float = 0.21

        init(cents: Float, milliseconds: Float) {
            delay = milliseconds * 0.001 * Float(rate)
            step = (1 - powf(2, cents / 1200)) / Self.sweep
        }

        mutating func process(_ input: DelayLine) -> Float {
            let other = phase < 0.5 ? phase + 0.5 : phase - 0.5
            let first = input.fractional(delay + Self.sweep * (phase - 0.5))
            let second = input.fractional(delay + Self.sweep * (other - 0.5))
            let weight = 0.5 - 0.5 * cosf(2 * .pi * phase)
            phase += step
            if phase >= 1 { phase -= 1 }
            if phase < 0 { phase += 1 }
            return first * weight + second * (1 - weight)
        }
    }

    struct PeakMeter {
        private var a = SIMD2<Float>.zero, b = SIMD2<Float>.zero, c = SIMD2<Float>.zero

        mutating func peak(_ d: SIMD2<Float>) -> Float {
            let delta = c - b
            let slope = (c - a) * 0.5
            let curve = (delta * 3 - (d - b) * 0.5) - slope * 2
            let cubic = slope + (d - b) * 0.5 - delta * 2
            var result = max(abs(d.x), abs(d.y))
            for sub in 1...3 {
                let x = Float(sub) * 0.25
                let value = b + x * (slope + x * (curve + x * cubic))
                result = max(result, abs(value.x), abs(value.y))
            }
            (a, b, c) = (b, c, d)
            return result
        }
    }

    struct Limiter {
        static let lookahead = 192
        static let ceiling = amplitude(-1.4)
        private let drive: Float
        private var buffer = Array(repeating: SIMD2<Float>.zero, count: lookahead)
        private var head = 0, holding = 0
        private var gain: Float = 1
        private var meter = PeakMeter()

        init(peak: Float) {
            drive = min(amplitude(8), amplitude(0.8) * Self.ceiling / max(0.001, peak))
        }

        mutating func process(_ input: SIMD2<Float>) -> SIMD2<Float> {
            let signal = input * drive
            let required = min(1, Self.ceiling / max(0.001, meter.peak(signal)))
            if required < gain {
                gain = required
                holding = Self.lookahead + 2
            } else if holding > 0 {
                holding -= 1
            } else {
                // About a 63 ms release. Both channels share the same gain.
                gain += 0.00033 * (required - gain)
            }
            let output = buffer[head] * gain
            buffer[head] = signal
            head += 1
            if head == buffer.count { head = 0 }
            return output
        }
    }

    // Convolve the same measured system hall used in the approved mix, with a separate
    // early field and a filtered late field whose decay is calibrated at render time.
    static func renderHall(voice: URL, early: URL, late: URL, directory: URL) throws {
        let impulse = directory.appendingPathComponent("impulse.caf")
        let response = directory.appendingPathComponent("impulse-wet.caf")
        defer {
            try? FileManager.default.removeItem(at: impulse)
            try? FileManager.default.removeItem(at: response)
        }
        let inputFrames = 5 * rate
        let impulseOffset = rate / 10
        try writeImpulse(at: impulse, count: inputFrames, offset: impulseOffset)

        var settings = VocalSettings()
        settings.tuning = VocalTuning(room: .hall)
        try TakeEffectsPreview.renderVocal(from: impulse, to: response, settings: settings, mode: .wetReverb)
        let file = try AVAudioFile(forReading: response)
        let samples = try buffer(file.processingFormat, capacity: AVAudioFrameCount(inputFrames))
        try file.read(into: samples)
        guard samples.frameLength == inputFrames, let wave = samples.floatChannelData else {
            throw AppFailure(message: "无法读取自动混音的大厅响应。")
        }
        let count = inputFrames - impulseOffset
        var earlyLeft = Filter.highPass(240), earlyRight = Filter.highPass(240)
        var earlyTopLeft = Filter.lowPass(4600), earlyTopRight = Filter.lowPass(4600)
        var lateLeft = Filter.highPass(225), lateRight = Filter.highPass(225)
        var lateTopLeft = Filter.lowPass(2170), lateTopRight = Filter.lowPass(2170)
        var first = [Array(repeating: Float(0), count: rate / 8), Array(repeating: Float(0), count: rate / 8)]
        var tail = [Array(repeating: Float(0), count: count), Array(repeating: Float(0), count: count)]
        for index in 0..<count {
            let time = Float(index) / Float(rate)
            if index < first[0].count {
                let sample = index + impulseOffset + Int(0.017 * Double(rate))
                let window = smooth((0.093 - time) / 0.046)
                let left = earlyTopLeft.process(earlyLeft.process(wave[0][sample] * window))
                let right = earlyTopRight.process(earlyRight.process(wave[1][sample] * window))
                let spread = width(SIMD2(left, right), 1.12 * 0.79)
                first[0][index] = spread.x
                first[1][index] = spread.y
            }
            let envelope = smooth((time - 0.052) / 0.064)
            let last = smooth((4.5 - time) / 0.4)
            let left = lateTopLeft.process(lateLeft.process(wave[0][index + impulseOffset] * envelope))
            let right = lateTopRight.process(lateRight.process(wave[1][index + impulseOffset] * envelope))
            let spread = width(SIMD2(left, right), 0.83) * last
            tail[0][index] = spread.x
            tail[1][index] = spread.y
        }
        for _ in 0..<3 {
            guard let measured = decay(of: tail) else { break }
            let slope = -3 * logf(10) * (1 / 2.7 - 1 / measured)
            for index in 0..<count {
                let gain = expf(slope * max(0, Float(index) / Float(rate) - 0.106))
                tail[0][index] *= gain
                tail[1][index] *= gain
            }
        }
        try convolve(voice, to: early, kernels: first, block: 16384)
        try convolve(voice, to: late, kernels: tail, block: 65536)
    }

    private static func decay(of channels: [[Float]]) -> Float? {
        let count = channels[0].count
        var reverse = Array(repeating: Double(0), count: count)
        var energy = 0.0
        for index in (0..<count).reversed() {
            energy += Double(channels[0][index] * channels[0][index] + channels[1][index] * channels[1][index])
            reverse[index] = energy
        }
        let start = Int(0.16 * Double(rate))
        let reference = reverse[start]
        guard reference > 1e-12 else { return nil }
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for index in stride(from: start, to: count, by: 48) {
            let db = 10 * log10(max(1e-20, reverse[index] / reference))
            guard (-35 ... -5).contains(db) else { continue }
            let x = Double(index) / Double(rate)
            n += 1; sx += x; sy += db; sxx += x * x; sxy += x * db
        }
        let denominator = n * sxx - sx * sx
        guard n > 30, denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        let seconds = -60 / slope
        return (0.25...10).contains(seconds) ? Float(seconds) : nil
    }

    private static func writeImpulse(at url: URL, count: Int, offset: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let samples = try buffer(format, capacity: AVAudioFrameCount(count))
        samples.frameLength = AVAudioFrameCount(count)
        let data = samples.floatChannelData![0]
        data.update(repeating: 0, count: count)
        data[offset] = 0.5
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: samples)
    }

    private static func buffer(_ format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppFailure(message: "无法为自动混音分配音频缓冲区。")
        }
        return buffer
    }

    private static func convolve(_ source: URL, to destination: URL, kernels: [[Float]], block: Int) throws {
        let input = try AVAudioFile(forReading: source)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
        var settings = outputFormat.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        let inputBuffer = try buffer(input.processingFormat, capacity: AVAudioFrameCount(block))
        let outputBuffer = try buffer(outputFormat, capacity: AVAudioFrameCount(block))
        let tailLength = kernels[0].count - 1
        var size = 1
        while size < block + tailLength { size *= 2 }
        let fft = try FFT(size: size)
        var spectra: [Spectrum] = []
        for kernel in kernels {
            var spectrum = Spectrum(size)
            spectrum.load(count: kernel.count) { kernel[$0] }
            fft.forward(&spectrum)
            spectra.append(spectrum)
        }
        var sourceFFT = Spectrum(size), outputFFT = Spectrum(size)
        var carried = Array(repeating: Array(repeating: Float(0), count: tailLength), count: 2)
        let scale = 1 / Float(size)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: inputBuffer)
            let count = Int(inputBuffer.frameLength)
            guard count > 0 else { throw AppFailure(message: "无法完整读取大厅混响的输入。") }
            let voice = inputBuffer.floatChannelData![0]
            sourceFFT.load(count: count) { voice[$0] }
            fft.forward(&sourceFFT)
            outputBuffer.frameLength = inputBuffer.frameLength
            for channel in 0..<2 {
                let kernel = spectra[channel]
                for i in 0..<size {
                    outputFFT.real[i] = sourceFFT.real[i] * kernel.real[i] - sourceFFT.imaginary[i] * kernel.imaginary[i]
                    outputFFT.imaginary[i] = sourceFFT.real[i] * kernel.imaginary[i] + sourceFFT.imaginary[i] * kernel.real[i]
                }
                fft.inverse(&outputFFT)
                let samples = outputBuffer.floatChannelData![channel]
                var overlap = carried[channel]
                for i in 0..<count {
                    samples[i] = scale * outputFFT.real[i] + (i < tailLength ? overlap[i] : 0)
                }
                for i in 0..<tailLength {
                    let next = count + i
                    overlap[i] = scale * outputFFT.real[next] + (next < tailLength ? overlap[next] : 0)
                }
                carried[channel] = overlap
            }
            try output.write(from: outputBuffer)
        }
    }

    private struct Spectrum {
        var real: [Float]
        var imaginary: [Float]

        init(_ length: Int) {
            real = Array(repeating: 0, count: length)
            imaginary = real
        }

        mutating func load(count: Int, sample: (Int) -> Float) {
            for i in 0..<count { real[i] = sample(i) }
            for i in count..<real.count { real[i] = 0 }
            imaginary.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: $0.count) }
        }
    }

    private final class FFT {
        private let setup: FFTSetup
        private let exponent: vDSP_Length

        init(size: Int) throws {
            exponent = vDSP_Length(size.trailingZeroBitCount)
            guard let setup = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2)) else {
                throw AppFailure(message: "无法初始化自动混音的频域处理。")
            }
            self.setup = setup
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func forward(_ buffer: inout Spectrum) { transform(&buffer, direction: FFTDirection(FFT_FORWARD)) }
        func inverse(_ buffer: inout Spectrum) { transform(&buffer, direction: FFTDirection(FFT_INVERSE)) }

        private func transform(_ buffer: inout Spectrum, direction: FFTDirection) {
            buffer.real.withUnsafeMutableBufferPointer { real in
                buffer.imaginary.withUnsafeMutableBufferPointer { imaginary in
                    var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, exponent, direction)
                }
            }
        }
    }
}
