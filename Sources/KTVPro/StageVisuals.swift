import SwiftUI
import AppKit

/// Frame-rate-independent visual smoother shared by Canvas draw passes without triggering SwiftUI @Published diffs.
@MainActor
final class StageVisualState {
    var smoothedEnergy: Double = 0
    var smoothedBrightness: Double = 0.35
    var smoothedClip: Double = 0
    var smoothedActive: Double = 0
    var phase: Double = 0
    var lastTime: TimeInterval?
    var ribbon = Array(repeating: Float(0), count: CaptureBridge.ribbonLength)
    var smoothedRibbon = Array(repeating: Double(0), count: CaptureBridge.ribbonLength)

    func step(at now: TimeInterval, bridge: CaptureBridge, micEnabled: Bool, isPlaying: Bool,
              isRecording: Bool, reverb: Float) -> StageAudioMetrics {
        let dt: Double
        if let last = lastTime {
            dt = min(0.05, max(0.001, now - last))
        } else {
            dt = 1.0 / 60.0
        }
        lastTime = now

        let metrics = micEnabled ? bridge.copyStageSignal(into: &ribbon) : StageAudioMetrics()
        if !micEnabled {
            for i in ribbon.indices { ribbon[i] = 0 }
        }

        let targetEnergy = micEnabled ? Double(metrics.energy) : 0
        let targetBrightness = micEnabled ? Double(metrics.brightness) : 0.35
        let clippingNow = micEnabled && metrics.clipUntil > ProcessInfo.processInfo.systemUptime
        let targetClip: Double = clippingNow ? 1 : 0
        let targetActive: Double = (isPlaying || isRecording || targetEnergy > 0.05) ? 1 : 0

        // Higher reverb yields a slightly longer, dreamier visual decay tail.
        let reverbFactor = Double(min(45, max(0, reverb))) / 45.0
        let attackRate = 18.0
        let releaseRate = 6.2 - reverbFactor * 3.0
        let energyRate = targetEnergy >= smoothedEnergy ? attackRate : releaseRate
        smoothedEnergy += (targetEnergy - smoothedEnergy) * (1 - exp(-energyRate * dt))
        smoothedBrightness += (targetBrightness - smoothedBrightness) * (1 - exp(-5.0 * dt))
        let clipRate = targetClip > smoothedClip ? 24.0 : 3.2
        smoothedClip += (targetClip - smoothedClip) * (1 - exp(-clipRate * dt))
        smoothedActive += (targetActive - smoothedActive) * (1 - exp(-2.8 * dt))

        let speed = 0.22 + (isPlaying ? 0.26 : 0) + (isRecording ? 0.14 : 0) + smoothedEnergy * 0.72
        phase += dt * speed

        let ribbonRate = 16.0
        let alpha = 1 - exp(-ribbonRate * dt)
        for i in smoothedRibbon.indices {
            smoothedRibbon[i] += (Double(ribbon[i]) - smoothedRibbon[i]) * alpha
        }
        return metrics
    }
}

/// Audio-reactive atmospheric stage backdrop + perimeter vocal sweet-spot / clip halo.
struct StageAmbientBackdrop: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showsVideo: Bool
    let focusStage: Bool
    @State private var visual = StageVisualState()

    private var shouldAnimate: Bool {
        !reduceMotion && (model.isPlaying || model.isRecording || model.microphoneEnabled || model.isTestingMic)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !shouldAnimate)) { timeline in
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let metrics = visual.step(at: now, bridge: model.audio.bridge,
                                          micEnabled: model.microphoneEnabled,
                                          isPlaying: model.isPlaying,
                                          isRecording: model.isRecording,
                                          reverb: model.reverb)
                if showsVideo {
                    drawVideoAmbient(in: &context, size: size, metrics: metrics)
                } else {
                    drawStageAmbient(in: &context, size: size, metrics: metrics)
                }
                drawVocalPerimeterHalo(in: &context, size: size, metrics: metrics)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawStageAmbient(in context: inout GraphicsContext, size: CGSize, metrics: StageAudioMetrics) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(StudioTheme.canvas))

        let t = reduceMotion ? 0.0 : visual.phase
        let energy = visual.smoothedEnergy
        let bright = visual.smoothedBrightness
        let active = visual.smoothedActive
        let recording = model.isRecording ? 1.0 : 0.0
        let scaleBoost = focusStage ? 1.15 : 1.0
        let minDim = min(size.width, size.height)

        // Blend layer for luminous studio light orbs.
        context.drawLayer { layer in
            layer.blendMode = .plusLighter

            // Orb 1: Deep studio violet anchor drifting gently across upper stage.
            let orb1Center = CGPoint(
                x: size.width * (0.48 + 0.14 * sin(t * 0.55)),
                y: size.height * (0.14 + 0.08 * cos(t * 0.41))
            )
            let orb1Radius = max(size.width, size.height) * (0.58 + energy * 0.14) * scaleBoost
            let orb1Alpha = 0.18 + active * 0.08 + energy * 0.16
            let orb1Gradient = Gradient(stops: [
                .init(color: StudioTheme.violet.opacity(orb1Alpha), location: 0),
                .init(color: StudioTheme.violet.opacity(orb1Alpha * 0.34), location: 0.48),
                .init(color: .clear, location: 1)
            ])
            layer.fill(
                Path(ellipseIn: CGRect(x: orb1Center.x - orb1Radius, y: orb1Center.y - orb1Radius,
                                       width: orb1Radius * 2, height: orb1Radius * 2)),
                with: .radialGradient(orb1Gradient, center: orb1Center, startRadius: 0, endRadius: orb1Radius)
            )

            // Orb 2: Warm vocal bloom (shifts from sakura rose toward golden amber as voice brightens).
            let orb2Center = CGPoint(
                x: size.width * (0.52 + 0.18 * cos(t * 0.68 + 0.9)),
                y: size.height * (0.50 + 0.11 * sin(t * 0.53))
            )
            let orb2Radius = minDim * (0.44 + energy * 0.34) * scaleBoost
            let orb2Alpha = 0.045 + active * 0.045 + energy * 0.24
            let warmCore = Color(
                red: 1.0,
                green: 0.48 + bright * 0.30,
                blue: 0.68 - bright * 0.22
            )
            let orb2Gradient = Gradient(stops: [
                .init(color: warmCore.opacity(orb2Alpha), location: 0),
                .init(color: StudioTheme.rose.opacity(orb2Alpha * 0.38), location: 0.5),
                .init(color: .clear, location: 1)
            ])
            layer.fill(
                Path(ellipseIn: CGRect(x: orb2Center.x - orb2Radius, y: orb2Center.y - orb2Radius,
                                       width: orb2Radius * 2, height: orb2Radius * 2)),
                with: .radialGradient(orb2Gradient, center: orb2Center, startRadius: 0, endRadius: orb2Radius)
            )

            // Orb 3: Soft lavender / amber counter-glow on lower-left horizon.
            let orb3Center = CGPoint(
                x: size.width * (0.26 + 0.14 * sin(t * 0.47 + 2.3)),
                y: size.height * (0.78 + 0.07 * cos(t * 0.62))
            )
            let orb3Radius = minDim * (0.46 + energy * 0.22) * scaleBoost
            let orb3Alpha = 0.055 + active * 0.04 + energy * 0.14
            let orb3Color = recording > 0.5 ? StudioTheme.live : StudioTheme.lavender
            let orb3Gradient = Gradient(stops: [
                .init(color: orb3Color.opacity(orb3Alpha), location: 0),
                .init(color: StudioTheme.amber.opacity(orb3Alpha * 0.35), location: 0.55),
                .init(color: .clear, location: 1)
            ])
            layer.fill(
                Path(ellipseIn: CGRect(x: orb3Center.x - orb3Radius, y: orb3Center.y - orb3Radius,
                                       width: orb3Radius * 2, height: orb3Radius * 2)),
                with: .radialGradient(orb3Gradient, center: orb3Center, startRadius: 0, endRadius: orb3Radius)
            )

            // Recording "ON AIR" upper studio rim wash.
            if recording > 0.01 {
                let pulse = reduceMotion ? 0.5 : (0.5 + 0.5 * sin(t * 2.2))
                let recCenter = CGPoint(x: size.width * 0.5, y: -size.height * 0.08)
                let recRadius = max(size.width * 0.62, size.height * 0.42)
                let recAlpha = (0.11 + pulse * 0.05 + energy * 0.08) * recording
                let recGrad = Gradient(stops: [
                    .init(color: StudioTheme.live.opacity(recAlpha), location: 0),
                    .init(color: StudioTheme.rose.opacity(recAlpha * 0.25), location: 0.55),
                    .init(color: .clear, location: 1)
                ])
                layer.fill(
                    Path(ellipseIn: CGRect(x: recCenter.x - recRadius, y: recCenter.y - recRadius,
                                           width: recRadius * 2, height: recRadius * 2)),
                    with: .radialGradient(recGrad, center: recCenter, startRadius: 0, endRadius: recRadius)
                )
            }

            // Delicate harmonic light ribbons sweeping behind lyrics when active.
            if !reduceMotion && (active > 0.02 || energy > 0.02) {
                drawHarmonicWaves(in: &layer, size: size, t: t, energy: energy, active: active, bright: bright)
            }
        }
    }

    private func drawHarmonicWaves(in layer: inout GraphicsContext, size: CGSize, t: Double,
                                   energy: Double, active: Double, bright: Double) {
        let baseY = size.height * 0.54
        let steps = 48
        for index in 0..<2 {
            let offset = Double(index) * 1.65
            let amplitude = (6.0 + active * 7.0 + energy * (index == 0 ? 34.0 : 22.0))
            let freq = index == 0 ? 2.1 : 3.2
            var path = Path()
            for step in 0...steps {
                let u = Double(step) / Double(steps)
                let envelope = sin(u * .pi)
                let x = u * size.width
                let y = baseY + (index == 0 ? -18 : 22)
                    + sin(u * .pi * freq + t * (1.35 + Double(index) * 0.45) + offset) * amplitude * envelope
                    + cos(u * .pi * (freq * 1.7) - t * 0.9) * (amplitude * 0.28) * envelope
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let alpha = (index == 0 ? 0.08 : 0.055) * active + energy * (index == 0 ? 0.16 : 0.11)
            let waveGradient = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: (index == 0 ? StudioTheme.accent : StudioTheme.lavender).opacity(alpha), location: 0.28),
                .init(color: (bright > 0.55 ? StudioTheme.amber : StudioTheme.lyric).opacity(alpha * 1.15), location: 0.55),
                .init(color: StudioTheme.violet.opacity(alpha * 0.8), location: 0.82),
                .init(color: .clear, location: 1)
            ])
            layer.stroke(
                path,
                with: .linearGradient(waveGradient, startPoint: CGPoint(x: 0, y: baseY), endPoint: CGPoint(x: size.width, y: baseY)),
                style: StrokeStyle(lineWidth: index == 0 ? 1.6 : 1.1, lineCap: .round)
            )
        }
    }

    private func drawVideoAmbient(in context: inout GraphicsContext, size: CGSize, metrics: StageAudioMetrics) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(.black))

        let energy = visual.smoothedEnergy
        let active = visual.smoothedActive
        let bottomCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.92)
        let radius = max(size.width * 0.65, size.height * 0.48)
        let alpha = 0.12 + active * 0.05 + energy * 0.16
        let grad = Gradient(stops: [
            .init(color: StudioTheme.violet.opacity(alpha), location: 0),
            .init(color: StudioTheme.rose.opacity(alpha * 0.42), location: 0.45),
            .init(color: .clear, location: 1)
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: bottomCenter.x - radius, y: bottomCenter.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(grad, center: bottomCenter, startRadius: 0, endRadius: radius)
        )
    }

    /// Subtle peripheral vocal sweet-spot & clip halo along the stage border.
    private func drawVocalPerimeterHalo(in context: inout GraphicsContext, size: CGSize, metrics: StageAudioMetrics) {
        guard model.microphoneEnabled else { return }
        let energy = visual.smoothedEnergy
        let clip = visual.smoothedClip
        let hot = metrics.peakDB > -4.0

        // Sweet-spot luminous floor glow proportional to singing energy.
        if energy > 0.04 {
            let glowHeight = min(size.height * 0.22, 110)
            let baseColor: Color = clip > 0.15 ? StudioTheme.live : (hot ? StudioTheme.amber : StudioTheme.accent)
            let alpha = min(0.28, energy * 0.24 + clip * 0.12)
            let floorGrad = Gradient(stops: [
                .init(color: baseColor.opacity(alpha), location: 0),
                .init(color: baseColor.opacity(alpha * 0.25), location: 0.45),
                .init(color: .clear, location: 1)
            ])
            let floorRect = CGRect(x: 0, y: size.height - glowHeight, width: size.width, height: glowHeight)
            context.fill(
                Path(floorRect),
                with: .linearGradient(floorGrad,
                                      startPoint: CGPoint(x: size.width * 0.5, y: size.height),
                                      endPoint: CGPoint(x: size.width * 0.5, y: size.height - glowHeight))
            )
        }

        // Crisp coral-red perimeter alert pulse on clipping.
        if clip > 0.02 {
            let strokeRect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            context.stroke(
                Path(roundedRect: strokeRect, cornerRadius: 4),
                with: .color(StudioTheme.live.opacity(0.68 * clip)),
                lineWidth: 2.5
            )
            let topGlowHeight = min(size.height * 0.16, 72)
            let topGrad = Gradient(stops: [
                .init(color: StudioTheme.live.opacity(0.26 * clip), location: 0),
                .init(color: .clear, location: 1)
            ])
            context.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: topGlowHeight)),
                with: .linearGradient(topGrad,
                                      startPoint: CGPoint(x: size.width * 0.5, y: 0),
                                      endPoint: CGPoint(x: size.width * 0.5, y: topGlowHeight))
            )
        }
    }
}

/// Sleek real-time mirrored vocal energy ribbon docked along the bottom edge of the stage.
struct VocalEnergyRibbon: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compact: Bool
    let focusStage: Bool
    @State private var visual = StageVisualState()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let metrics = visual.step(at: now, bridge: model.audio.bridge,
                                          micEnabled: model.microphoneEnabled,
                                          isPlaying: model.isPlaying,
                                          isRecording: model.isRecording,
                                          reverb: model.reverb)
                let samples = visual.smoothedRibbon
                guard !samples.isEmpty else { return }

                let midY = size.height * 0.5
                let maxHalfHeight = max(4, size.height * 0.44)
                let count = samples.count
                let barSpacing: CGFloat = focusStage ? 5 : 4
                let totalWidth = min(size.width - 40, CGFloat(count) * (barSpacing + 2.5))
                let startX = (size.width - totalWidth) * 0.5
                let stepX = totalWidth / CGFloat(max(1, count - 1))
                let barWidth: CGFloat = focusStage ? 2.6 : 2.2
                let clipping = metrics.clipUntil > ProcessInfo.processInfo.systemUptime

                // Subtle center baseline.
                let baseline = Path { path in
                    path.move(to: CGPoint(x: startX, y: midY))
                    path.addLine(to: CGPoint(x: startX + totalWidth, y: midY))
                }
                context.stroke(baseline, with: .color(.white.opacity(0.08)), lineWidth: 1)

                for i in 0..<count {
                    let u = Double(i) / Double(max(1, count - 1))
                    // Fade tail softly on the left, stay vivid toward the live right edge.
                    let tailFade = min(1.0, u * 3.2) * (1.0 - max(0.0, (u - 0.94) / 0.06) * 0.25)
                    let value = max(0, min(1, samples[i]))
                    let shaped = pow(value, 0.82)
                    let halfHeight = max(1.5, CGFloat(shaped) * maxHalfHeight)
                    let x = startX + CGFloat(i) * stepX
                    let barRect = CGRect(x: x - barWidth * 0.5, y: midY - halfHeight,
                                         width: barWidth, height: halfHeight * 2)
                    let barColor: Color
                    if clipping && i >= count - 6 {
                        barColor = StudioTheme.live
                    } else if value > 0.84 {
                        barColor = StudioTheme.amber
                    } else if model.isRecording {
                        barColor = u > 0.72 ? StudioTheme.lyric : StudioTheme.rose
                    } else {
                        barColor = u > 0.65 ? StudioTheme.lyric : StudioTheme.accent
                    }
                    let alpha = (0.16 + shaped * 0.80) * tailFade
                    context.fill(Path(roundedRect: barRect, cornerRadius: barWidth * 0.5),
                                 with: .color(barColor.opacity(alpha)))
                }

                // Live tip dot on the rightmost edge confirming active mic feed.
                let tipX = startX + totalWidth
                let tipRadius: CGFloat = 2.5 + CGFloat(visual.smoothedEnergy) * 2.2
                let tipColor = clipping ? StudioTheme.live : (model.isRecording ? StudioTheme.live : StudioTheme.lyric)
                let tipRect = CGRect(x: tipX - tipRadius, y: midY - tipRadius,
                                     width: tipRadius * 2, height: tipRadius * 2)
                context.fill(Path(ellipseIn: tipRect), with: .color(tipColor.opacity(0.45 + visual.smoothedEnergy * 0.55)))
            }
        }
        .frame(height: compact ? 22 : (focusStage ? 34 : 28))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Compact peripheral vocal health badge in the stage top bar.
struct VocalZoneBadge: View {
    let meter: AudioMeter
    let isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Zone {
        case clip, hot, sweet, idle
    }

    private var zone: Zone {
        if meter.clipUntil > ProcessInfo.processInfo.systemUptime { return .clip }
        if meter.peakDB > -4 { return .hot }
        if meter.rmsDB > -38 { return .sweet }
        return .idle
    }

    private var label: String {
        switch zone {
        case .clip: "输入过载 · 调低增益"
        case .hot: "接近峰值"
        case .sweet: isRecording ? "收音良好" : "人声活跃"
        case .idle: "麦克风待机"
        }
    }

    private var dotColor: Color {
        switch zone {
        case .clip: StudioTheme.live
        case .hot: StudioTheme.amber
        case .sweet: isRecording ? StudioTheme.live : StudioTheme.accent
        case .idle: Color.white.opacity(0.35)
        }
    }

    private var pillBackground: Color {
        switch zone {
        case .clip: StudioTheme.live.opacity(0.22)
        case .hot: StudioTheme.amber.opacity(0.15)
        case .sweet: StudioTheme.accent.opacity(0.12)
        case .idle: Color.white.opacity(0.06)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: zone == .idle ? .clear : dotColor.opacity(0.7), radius: 4)
            Text(label)
                .font(.system(size: 10, weight: zone == .clip ? .semibold : .medium))
                .foregroundStyle(zone == .clip ? StudioTheme.live : zone == .hot ? StudioTheme.amber : .primary.opacity(zone == .idle ? 0.65 : 0.92))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(pillBackground, in: Capsule())
        .overlay {
            Capsule().strokeBorder(zone == .clip ? StudioTheme.live.opacity(0.55) : StudioTheme.separator)
        }
        .help(String(format: "当前峰值 %.0f dBFS · 有效值 %.0f dBFS", meter.peakDB, meter.rmsDB))
        .animation(reduceMotion ? nil : StudioTheme.quick, value: zone)
    }
}

/// Three luminous breathing dots signaling an upcoming vocal entrance during intros or interludes.
private struct InterludeBreathingCue: View {
    let cue: InterludeCue
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let lit = cue.progress * 3.0
        VStack(spacing: compact ? 4 : 6) {
            HStack(spacing: compact ? 8 : 10) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(1.0, max(0.0, lit - Double(index)))
                    let activeDot = fill > 0.02 && fill < 0.99
                    Circle()
                        .fill(StudioTheme.lyric.opacity(0.20 + fill * 0.80))
                        .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                        .scaleEffect(!reduceMotion && activeDot ? 1.24 : (fill >= 0.99 ? 1.08 : 0.88))
                        .shadow(color: StudioTheme.accent.opacity(fill * 0.7), radius: fill * 7)
                }
                Text(String(format: "%.0fs", max(1, ceil(cue.remaining))))
                    .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(StudioTheme.lyric.opacity(0.75))
                    .padding(.leading, 2)
            }
            if !compact, !cue.nextLineText.isEmpty {
                Text("即将进唱 · \(cue.nextLineText)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 5 : 7)
        .background(.ultraThinMaterial.opacity(0.45), in: Capsule())
        .overlay { Capsule().strokeBorder(StudioTheme.separator.opacity(0.9)) }
        .accessibilityLabel("间奏，约 \(Int(ceil(cue.remaining))) 秒后进入下一句")
    }
}

/// Cinematic depth-of-field lyric display with 60fps sweep progress and interlude cues.
struct StageLyricDisplay: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compact: Bool
    let focusStage: Bool
    var upperFocus: Bool = false
    let searchLyrics: () -> Void
    @State private var followsPlayback = true

    private struct ScrollLayout: Equatable {
        let recording: Bool
        let focusStage: Bool
        let upperFocus: Bool
        let height: CGFloat
    }

    private var rowHeight: CGFloat {
        if compact { return 38 }
        return focusStage ? 64 : 52
    }

    private var activeIndex: Int? { model.currentLyricIndex }

    private var activeID: Int? {
        guard let index = activeIndex, model.lyrics.lines.indices.contains(index) else { return nil }
        return model.lyrics.lines[index].id
    }

    private var immersiveReading: Bool {
        model.isRecording || (followsPlayback && (model.isPlaying || focusStage))
    }

    var body: some View {
        if model.lyrics.lines.isEmpty {
            emptyLyricsState
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !compact && !focusStage {
                        lyricStatusStrip(using: proxy)
                    } else if !model.isRecording && !followsPlayback {
                        HStack {
                            Spacer()
                            returnToCurrentButton(using: proxy)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                    }
                    ZStack(alignment: .top) {
                        lyricList(using: proxy, recording: model.isRecording)
                        if model.isPlaying || model.isRecording {
                            interludeOverlay
                        }
                    }
                }
                .padding(.horizontal, compact ? 10 : (focusStage ? 36 : 18))
                .onChange(of: activeID) {
                    if model.isRecording || followsPlayback {
                        scrollToCurrent(using: proxy, animated: true)
                    }
                }
                .onChange(of: model.lyrics.lines) {
                    followsPlayback = true
                    scrollToCurrent(using: proxy, animated: false)
                }
            }
        }
    }

    private var emptyLyricsState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(StudioTheme.accent.opacity(0.10))
                    .frame(width: 68, height: 68)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(StudioTheme.action)
            }
            VStack(spacing: 6) {
                Text(model.librarySong?.title ?? "导入歌词，跟着伴奏唱")
                    .font(.system(size: focusStage ? 34 : 26, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                if let song = model.librarySong {
                    Text(song.artist).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Text(model.librarySong?.lyricStatus ?? "支持带时间戳的 LRC 与逐字增强 LRC 歌词")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("导入 LRC 歌词") { model.importLyrics() }.disabled(model.busy)
                Button("从 LRCLIB 搜索", action: searchLyrics).disabled(!model.canSearchLyrics)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricStatusStrip(using proxy: ScrollViewProxy) -> some View {
        HStack {
            Text(model.isRecording ? "录制中 · 自动居中跟随" : model.mediaReady ? "滚动查看 · 点击任意句跳转" : "导入伴奏后开始同步歌词")
                .foregroundStyle(.secondary.opacity(0.85))
            Spacer()
            if model.isRecording || followsPlayback {
                Label("跟随播放", systemImage: "scope").foregroundStyle(.secondary.opacity(0.85))
            } else {
                returnToCurrentButton(using: proxy)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private func returnToCurrentButton(using proxy: ScrollViewProxy) -> some View {
        Button {
            followsPlayback = true
            scrollToCurrent(using: proxy, animated: true)
        } label: {
            Label("回到当前句", systemImage: "scope")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(StudioTheme.accent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTheme.accent)
    }

    private var interludeOverlay: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !model.isPlaying)) { _ in
            let now = model.liveLyricSeconds()
            let index = model.lyrics.index(at: now)
            Group {
                if let cue = model.lyrics.interludeCue(at: now, currentIndex: index) {
                    InterludeBreathingCue(cue: cue, compact: compact, reduceMotion: reduceMotion)
                        .padding(.top, compact ? 4 : 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func lyricList(using proxy: ScrollViewProxy, recording: Bool) -> some View {
        let lines = model.lyrics.lines
        return GeometryReader { viewport in
            // In mascot/photo modes, keep the active lyric higher (around the 2nd visible line)
            // so the visual center stays balanced right below the character.
            let topInset = upperFocus
                ? max(14, min(62, viewport.size.height * 0.24 - rowHeight * 0.5))
                : max(14, (viewport.size.height - rowHeight) / 2)
            let bottomInset = upperFocus
                ? max(36, viewport.size.height * 0.72)
                : max(14, (viewport.size.height - rowHeight) / 2)
            ScrollView(showsIndicators: !immersiveReading) {
                LazyVStack(spacing: compact ? 6 : (focusStage ? 14 : 10)) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        StageLyricRow(
                            model: model,
                            line: line,
                            index: index,
                            activeIndex: activeIndex,
                            compact: compact,
                            focusStage: focusStage,
                            immersive: immersiveReading
                        ) {
                            let previousID = activeID
                            model.seekToLyric(line)
                            followsPlayback = true
                            if activeID == previousID { scrollToCurrent(using: proxy, animated: true) }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
            .scrollDisabled(recording)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: upperFocus ? 0.08 : (compact ? 0.14 : 0.18)),
                        .init(color: .black, location: upperFocus ? 0.78 : (compact ? 0.84 : 0.82)),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .background {
                StageLyricScrollInput { if !model.isRecording { followsPlayback = false } }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityLabel("同步歌词")
            .task(id: ScrollLayout(recording: recording, focusStage: focusStage, upperFocus: upperFocus, height: viewport.size.height)) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                if recording { followsPlayback = true }
                if followsPlayback { scrollToCurrent(using: proxy, animated: false) }
            }
        }
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = activeID ?? model.lyrics.lines.first?.id else { return }
        let anchor: UnitPoint = upperFocus ? UnitPoint(x: 0.5, y: 0.25) : .center
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.30)) { proxy.scrollTo(id, anchor: anchor) }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

private struct StageLyricRow: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let line: LyricLine
    let index: Int
    let activeIndex: Int?
    let compact: Bool
    let focusStage: Bool
    let immersive: Bool
    let seek: () -> Void
    @State private var hovered = false

    private var isActive: Bool { activeIndex == index }

    private var distance: Int? {
        activeIndex.map { abs(index - $0) }
    }

    private var fontSize: CGFloat {
        if compact { return isActive ? 19 : 15 }
        if focusStage { return isActive ? 32 : 22 }
        return isActive ? 25 : 18
    }

    private var rowOpacity: Double {
        if isActive { return 1.0 }
        if hovered { return 0.88 }
        guard immersive, let distance else { return 0.68 }
        switch distance {
        case 1: return 0.54
        case 2: return 0.32
        default: return 0.17
        }
    }

    private var depthBlur: CGFloat {
        guard !reduceMotion, immersive, !hovered, let distance, distance > 0 else { return 0 }
        switch distance {
        case 1: return compact ? 0.3 : 0.45
        case 2: return compact ? 0.8 : 1.15
        default: return compact ? 1.4 : 1.9
        }
    }

    private var showTimestamp: Bool {
        !immersive || hovered
    }

    var body: some View {
        let recording = model.isRecording
        let time = preciseTimeLabel(max(0, line.time + model.lyricDelay))
        let content = rowContent(time: time, recording: recording)
        if recording || line.text.isEmpty {
            content
        } else {
            Button(action: seek) { content }
                .buttonStyle(.plain)
                .disabled(model.busy || !model.mediaReady)
                .onHover { hovered = $0 }
                .help("跳到 \(time)")
        }
    }

    private func rowContent(time: String, recording: Bool) -> some View {
        let displayText = line.text.isEmpty ? "···  间奏  ···" : line.text
        return HStack(spacing: 12) {
            Text(time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isActive ? StudioTheme.lyric.opacity(0.85) : Color.secondary.opacity(0.75))
                .frame(width: 48, alignment: .leading)
                .opacity(showTimestamp ? 1 : 0)
                .accessibilityHidden(true)

            VStack(spacing: isActive && !line.text.isEmpty ? 6 : 0) {
                if isActive && !line.text.isEmpty {
                    activeSweepingText(displayText, recording: recording)
                } else {
                    Text(displayText)
                        .font(.system(size: line.text.isEmpty ? max(12, fontSize - 5) : fontSize,
                                      weight: line.text.isEmpty ? .medium : .regular,
                                      design: .rounded))
                        .tracking(line.text.isEmpty ? 2 : 0)
                        .foregroundStyle(line.text.isEmpty ? StudioTheme.accent.opacity(0.65) : .white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)

            Color.clear.frame(width: 48, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isActive ? (compact ? 6 : 10) : (compact ? 4 : 6))
        .background {
            if hovered && !model.isRecording {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.055))
            }
        }
        .opacity(rowOpacity)
        .blur(radius: depthBlur)
        .scaleEffect(isActive ? (recording ? 1.06 : 1.03) : 0.985)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isActive)
        .animation(reduceMotion ? nil : StudioTheme.quick, value: hovered)
    }

    private func activeSweepingText(_ text: String, recording: Bool) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !model.isPlaying)) { _ in
            let now = model.liveLyricSeconds()
            let progress = model.lyrics.lineProgress(at: now, lineIndex: index, songDuration: model.duration)
            let feather = 0.11
            let lead = reduceMotion ? 1.0 : min(1.0, max(0.0, progress))
            let stopA = max(0.0, lead - feather * 0.5)
            let stopB = min(1.0, lead + feather * 0.5)

            VStack(spacing: compact ? 4 : 7) {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(
                        reduceMotion
                        ? AnyShapeStyle(StudioTheme.lyricGlow)
                        : AnyShapeStyle(LinearGradient(
                            stops: [
                                .init(color: StudioTheme.lyricGlow, location: 0),
                                .init(color: StudioTheme.lyric, location: stopA),
                                .init(color: Color.white.opacity(0.46), location: stopB),
                                .init(color: Color.white.opacity(0.42), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    )
                    .shadow(color: (recording ? StudioTheme.rose : StudioTheme.accent).opacity(0.32 + lead * 0.18),
                            radius: focusStage ? 18 : 13, x: 0, y: 0)

                // Subtle phrase sweep rail beneath the active lyric.
                if !reduceMotion {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(width: focusStage ? 120 : (compact ? 72 : 96), height: 2.2)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(StudioTheme.action)
                                .frame(width: (focusStage ? 120 : (compact ? 72 : 96)) * CGFloat(lead), height: 2.2)
                        }
                        .opacity(model.isPlaying || progress > 0.01 ? 0.85 : 0.25)
                }
            }
        }
    }
}

/// Observe scroll input in this viewport only; programmatic scrolls should keep following.
private struct StageLyricScrollInput: NSViewRepresentable {
    let onBrowse: () -> Void

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) { view.onBrowse = onBrowse }

    final class View: NSView {
        var onBrowse: (() -> Void)?
        private var monitor: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(point) else { return event }
                if event.type == .scrollWheel ? event.momentumPhase.isEmpty : point.x >= self.bounds.maxX - 15 {
                    self.onBrowse?()
                }
                return event
            }
        }
    }
}
