import SwiftUI

enum StageVisualMode: String, CaseIterable, Identifiable {
    case ambient = "ambient"
    case flowerMascot = "flowerMascot"
    case photoMouth = "photoMouth"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ambient: "流光舞台"
        case .flowerMascot: "花小梨跟唱"
        case .photoMouth: "照片开口"
        }
    }

    var shortLabel: String {
        switch self {
        case .ambient: "流光"
        case .flowerMascot: "花小梨"
        case .photoMouth: "照片"
        }
    }

    var icon: String {
        switch self {
        case .ambient: "sparkles"
        case .flowerMascot: "camera.macro"
        case .photoMouth: "photo.on.rectangle.angled"
        }
    }

    var hasCharacter: Bool {
        self == .flowerMascot || self == .photoMouth
    }
}

fileprivate struct FloatingNote {
    var active = false
    var age: Double = 0
    var lifetime: Double = 1.6
    var startX: Double = 0
    var startY: Double = 0
    var driftX: Double = 0
    var rise: Double = 55
    var phase: Double = 0
    var symbol: String = "♪"
    var tintIndex: Int = 0
}

/// 60/120fps procedural animation state for the singing flower character (no @Published churn).
@MainActor
fileprivate final class FlowerMascotState {
    var mouthOpen: Double = 0
    /// Real-time formant-driven viseme weights: A ("啊" big open), O ("噢/呜" round), E ("咿/诶" wide smile).
    var vowelA: Double = 0.34
    var vowelO: Double = 0.33
    var vowelE: Double = 0.33
    var energy: Double = 0
    var petalBloom: Double = 0
    var headBounce: Double = 0
    var headTilt: Double = 0
    var happyEyes: Double = 0
    var clipStartle: Double = 0
    var blinkAmount: Double = 0
    var phase: Double = 0
    var lastTime: TimeInterval?

    private var nextBlinkIn: Double = 2.6
    private var blinkProgress: Double = -1
    private var noteCooldown: Double = 0
    private var noteSeed: UInt64 = 1
    private var ribbon = Array(repeating: Float(0), count: CaptureBridge.ribbonLength)
    var notes = Array(repeating: FloatingNote(), count: 6)

    func step(at now: TimeInterval, bridge: CaptureBridge, micEnabled: Bool,
              isPlaying: Bool, isRecording: Bool, reduceMotion: Bool) {
        let dt: Double
        if let last = lastTime {
            dt = min(0.05, max(0.001, now - last))
        } else {
            dt = 1.0 / 60.0
        }
        lastTime = now

        let metrics = micEnabled ? bridge.copyStageSignal(into: &ribbon) : StageAudioMetrics()
        let clipping = micEnabled && metrics.clipUntil > ProcessInfo.processInfo.systemUptime

        // Use AudioEngine's adaptive noise-floor + hysteresis voice gate so ambient room noise never opens the mouth.
        let targetOpen: Double = (micEnabled && metrics.voiceActive) ? Double(metrics.voiceLevel) : 0
        let targetEnergy: Double = (micEnabled && metrics.voiceActive) ? Double(metrics.energy) : 0

        // Responsive yet silky cartoon physics (zero jitter: ~35ms open, ~60ms smooth close, ~55ms vowel morph).
        let openRate = targetOpen >= mouthOpen ? 28.0 : 16.0
        mouthOpen += (targetOpen - mouthOpen) * (1 - exp(-openRate * dt))
        if targetOpen == 0 && mouthOpen < 0.015 { mouthOpen = 0 }

        let targetA = micEnabled ? Double(metrics.vowelA) : 0.34
        let targetO = micEnabled ? Double(metrics.vowelO) : 0.33
        let targetE = micEnabled ? Double(metrics.vowelE) : 0.33
        let vowelAlpha = 1 - exp(-18.0 * dt)
        vowelA += (targetA - vowelA) * vowelAlpha
        vowelO += (targetO - vowelO) * vowelAlpha
        vowelE += (targetE - vowelE) * vowelAlpha
        let vSum = max(0.001, vowelA + vowelO + vowelE)
        vowelA /= vSum
        vowelO /= vSum
        vowelE /= vSum

        energy += (targetEnergy - energy) * (1 - exp(-(targetEnergy >= energy ? 12.0 : 6.0) * dt))
        petalBloom += (mouthOpen - petalBloom) * (1 - exp(-9.0 * dt))

        let targetClip: Double = clipping ? 1.0 : 0.0
        clipStartle += (targetClip - clipStartle) * (1 - exp(-(clipping ? 26.0 : 5.0) * dt))

        let sustainedJoy: Double = (!clipping && mouthOpen > 0.62) ? min(1.0, (mouthOpen - 0.55) / 0.35) : 0
        happyEyes += (sustainedJoy - happyEyes) * (1 - exp(-7.0 * dt))

        if !reduceMotion {
            let tempoSpeed = 1.25 + (isPlaying ? 1.35 : 0) + (isRecording ? 0.35 : 0) + mouthOpen * 1.4
            phase += dt * tempoSpeed

            let idleBreath = sin(phase * 1.1) * 0.015
            let targetBounce = idleBreath - mouthOpen * 0.048
            headBounce += (targetBounce - headBounce) * (1 - exp(-14.0 * dt))

            let sway = sin(phase * 0.82) * (isPlaying ? 0.055 : 0.025) + sin(phase * 1.9) * mouthOpen * 0.032
            headTilt += (sway - headTilt) * (1 - exp(-8.0 * dt))
        } else {
            headBounce = 0
            headTilt = 0
        }

        // Organic eye blinking every ~2.8 - 5.2 seconds.
        if reduceMotion {
            blinkAmount = 0
        } else if blinkProgress >= 0 {
            blinkProgress += dt / 0.16
            if blinkProgress >= 1.0 {
                blinkProgress = -1
                blinkAmount = 0
                nextBlinkIn = 2.8 + nextRandom() * 2.5
            } else {
                blinkAmount = sin(blinkProgress * .pi)
            }
        } else {
            nextBlinkIn -= dt
            if nextBlinkIn <= 0 && clipStartle < 0.2 {
                blinkProgress = 0
            }
        }

        // Update floating musical note particles when singing actively.
        noteCooldown = max(0, noteCooldown - dt)
        if !reduceMotion && micEnabled && mouthOpen > 0.38 && noteCooldown <= 0 {
            spawnNote()
            noteCooldown = max(0.32, 0.95 - mouthOpen * 0.58)
        }
        for i in notes.indices where notes[i].active {
            notes[i].age += dt
            if notes[i].age >= notes[i].lifetime {
                notes[i].active = false
            }
        }
    }

    private func nextRandom() -> Double {
        noteSeed = noteSeed &* 6364136223846793005 &+ 1442695040888963407
        return Double((noteSeed >> 33) & 0xFFFF) / Double(0xFFFF)
    }

    private func spawnNote() {
        guard let index = notes.firstIndex(where: { !$0.active }) else { return }
        let side: Double = nextRandom() > 0.5 ? 1 : -1
        notes[index] = FloatingNote(
            active: true,
            age: 0,
            lifetime: 1.35 + nextRandom() * 0.55,
            startX: side * (0.38 + nextRandom() * 0.16),
            startY: -0.18 - nextRandom() * 0.22,
            driftX: side * (0.18 + nextRandom() * 0.14),
            rise: 0.36 + nextRandom() * 0.18,
            phase: nextRandom() * .pi * 2,
            symbol: nextRandom() > 0.45 ? "♪" : "♫",
            tintIndex: Int(nextRandom() * 3)
        )
    }
}

/// Hand-crafted vector singing flower mascot modeled after the user's coral-petal character.
struct FlowerSingerView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mini: Bool
    let focusStage: Bool
    @State private var mascot = FlowerMascotState()

    private var shouldAnimate: Bool {
        !reduceMotion || model.microphoneEnabled
    }

    // Authentic colors sampled from the character artwork.
    private static let inkColor = Color(red: 0.08, green: 0.06, blue: 0.08)
    private static let petalFill = Color(red: 0.95, green: 0.39, blue: 0.45)
    private static let petalDeep = Color(red: 0.87, green: 0.29, blue: 0.38)
    private static let bodyYellow = Color(red: 0.99, green: 0.92, blue: 0.50)
    private static let bodyShade = Color(red: 0.95, green: 0.85, blue: 0.40)
    private static let faceCream = Color(red: 0.995, green: 0.968, blue: 0.905)
    private static let leafGreen = Color(red: 0.28, green: 0.54, blue: 0.24)
    private static let cheekBlush = Color(red: 0.93, green: 0.54, blue: 0.52)
    private static let mouthInterior = Color(red: 0.36, green: 0.09, blue: 0.16)
    private static let tonguePink = Color(red: 0.95, green: 0.46, blue: 0.54)

    private struct PetalSpec {
        let angleDeg: Double
        let length: CGFloat
        let width: CGFloat
        let tipSkew: CGFloat
        let phaseOffset: Double
    }

    // 10 organic coral-pink petals matching the character's charming silhouette clockwise from top.
    private static let petals: [PetalSpec] = [
        PetalSpec(angleDeg: -102, length: 0.90, width: 0.39, tipSkew: -0.05, phaseOffset: 0.0),
        PetalSpec(angleDeg: -54,  length: 0.96, width: 0.37, tipSkew:  0.06, phaseOffset: 0.7),
        PetalSpec(angleDeg: -16,  length: 0.84, width: 0.35, tipSkew:  0.04, phaseOffset: 1.4),
        PetalSpec(angleDeg:  16,  length: 0.76, width: 0.34, tipSkew: -0.03, phaseOffset: 2.1),
        PetalSpec(angleDeg:  48,  length: 0.80, width: 0.37, tipSkew:  0.05, phaseOffset: 2.8),
        PetalSpec(angleDeg:  82,  length: 0.68, width: 0.36, tipSkew: -0.04, phaseOffset: 3.5),
        PetalSpec(angleDeg: 114,  length: 0.82, width: 0.36, tipSkew:  0.04, phaseOffset: 4.2),
        PetalSpec(angleDeg: 142,  length: 0.78, width: 0.35, tipSkew: -0.05, phaseOffset: 4.9),
        PetalSpec(angleDeg: 176,  length: 0.80, width: 0.37, tipSkew:  0.03, phaseOffset: 5.6),
        PetalSpec(angleDeg: -142, length: 0.85, width: 0.35, tipSkew: -0.04, phaseOffset: 6.1)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !shouldAnimate)) { timeline in
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                mascot.step(at: now, bridge: model.audio.bridge,
                            micEnabled: model.microphoneEnabled,
                            isPlaying: model.isPlaying,
                            isRecording: model.isRecording,
                            reduceMotion: reduceMotion)
                drawCharacter(in: &context, size: size)
            }
        }
        .overlay(alignment: .bottom) {
            if !mini && !model.microphoneEnabled {
                Text("启用麦克风后，花小梨会跟着你的歌声张嘴摇摆")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial.opacity(0.45), in: Capsule())
                    .overlay { Capsule().strokeBorder(StudioTheme.separator) }
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(model.microphoneEnabled ? "花小梨跟唱角色，实时响应麦克风声音" : "花小梨跟唱角色")
    }

    private func drawCharacter(in context: inout GraphicsContext, size: CGSize) {
        let unit = min(size.width, size.height) * (mini ? 0.38 : 0.35)
        let center = CGPoint(x: size.width * 0.5, y: size.height * (mini ? 0.50 : 0.49))
        let inkWidth = max(1.8, unit * 0.048)

        // Warm soft studio spotlight halo behind the flower so black ink & coral petals pop on dark canvas.
        let haloRadius = unit * (1.72 + CGFloat(mascot.petalBloom) * 0.24)
        let haloAlpha = (mini ? 0.16 : 0.18) + mascot.energy * 0.16
        let haloColor = mascot.clipStartle > 0.2 ? StudioTheme.live : StudioTheme.lyric
        let haloGrad = Gradient(stops: [
            .init(color: haloColor.opacity(haloAlpha), location: 0),
            .init(color: StudioTheme.accent.opacity(haloAlpha * 0.42), location: 0.46),
            .init(color: .clear, location: 1)
        ])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius * 0.92,
                                   width: haloRadius * 2, height: haloRadius * 1.84)),
            with: .radialGradient(haloGrad, center: center, startRadius: 0, endRadius: haloRadius)
        )

        // Subtle pulse ring when singing loudly.
        if !mini && mascot.mouthOpen > 0.18 {
            let ringR = unit * (1.28 + CGFloat(mascot.mouthOpen) * 0.28)
            let ringColor = mascot.clipStartle > 0.2 ? StudioTheme.live : StudioTheme.accent
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR * 0.94,
                                       width: ringR * 2, height: ringR * 1.88)),
                with: .color(ringColor.opacity(0.08 + mascot.mouthOpen * 0.18)),
                lineWidth: 1.4
            )
        }

        // Draw floating musical notes behind/around the petals.
        drawFloatingNotes(in: &context, center: center, unit: unit)

        // 1. Butter-yellow dome body (stays grounded with gentle squash & stretch).
        let bodySquashX = 1.0 + CGFloat(mascot.mouthOpen) * 0.032
        let bodySquashY = 1.0 - CGFloat(mascot.mouthOpen) * 0.024
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y + unit * 0.52)
            layer.scaleBy(x: bodySquashX, y: bodySquashY)
            drawBody(in: &layer, unit: unit, inkWidth: inkWidth)
        }

        // 2. Flower head (petals + cream face + green rim + eyes + lashes + cheeks + animated mouth).
        let headY = center.y - unit * 0.08 + CGFloat(mascot.headBounce) * unit
        let baseTilt = -0.095 + mascot.headTilt
        // Subtle expressive face squash & stretch responding to the active vowel shape.
        let faceScaleX = 1.0 + CGFloat((mascot.vowelE * 0.032 - mascot.vowelO * 0.030) * mascot.mouthOpen)
        let faceScaleY = 1.0 + CGFloat((mascot.vowelA * 0.036 - mascot.vowelE * 0.020) * mascot.mouthOpen)
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: headY)
            layer.rotate(by: Angle(radians: baseTilt))

            drawPetals(in: &layer, unit: unit, inkWidth: inkWidth)
            layer.scaleBy(x: faceScaleX, y: faceScaleY)
            drawFace(in: &layer, unit: unit, inkWidth: inkWidth)
            drawEyesAndLashes(in: &layer, unit: unit, inkWidth: inkWidth)
            drawNoseAndCheeks(in: &layer, unit: unit, inkWidth: inkWidth)
            drawMouth(in: &layer, unit: unit, inkWidth: inkWidth)

            if mascot.clipStartle > 0.15 {
                drawClipSweatDrop(in: &layer, unit: unit, inkWidth: inkWidth, opacity: mascot.clipStartle)
            }
        }
    }

    private func drawBody(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let w = unit * 0.92
        let h = unit * 0.80
        var bodyPath = Path()
        bodyPath.move(to: CGPoint(x: -w * 0.96, y: h * 0.80))
        bodyPath.addCurve(
            to: CGPoint(x: -w * 0.42, y: -h * 0.62),
            control1: CGPoint(x: -w * 1.02, y: h * 0.16),
            control2: CGPoint(x: -w * 0.72, y: -h * 0.34)
        )
        bodyPath.addCurve(
            to: CGPoint(x: w * 0.64, y: -h * 0.42),
            control1: CGPoint(x: -w * 0.06, y: -h * 0.92),
            control2: CGPoint(x: w * 0.46, y: -h * 0.80)
        )
        bodyPath.addCurve(
            to: CGPoint(x: w * 0.98, y: h * 0.78),
            control1: CGPoint(x: w * 0.88, y: -h * 0.02),
            control2: CGPoint(x: w * 1.06, y: h * 0.36)
        )
        bodyPath.addQuadCurve(
            to: CGPoint(x: -w * 0.96, y: h * 0.80),
            control: CGPoint(x: 0, y: h * 0.92)
        )
        bodyPath.closeSubpath()

        let bodyGrad = Gradient(colors: [Self.bodyYellow, Self.bodyShade])
        context.fill(bodyPath, with: .linearGradient(bodyGrad,
                                                     startPoint: CGPoint(x: 0, y: -h * 0.6),
                                                     endPoint: CGPoint(x: 0, y: h * 0.85)))

        // Hand-inked outer side curves (open at the bottom just like the original drawing).
        var outline = Path()
        outline.move(to: CGPoint(x: -w * 0.93, y: h * 0.80))
        outline.addCurve(
            to: CGPoint(x: -w * 0.42, y: -h * 0.62),
            control1: CGPoint(x: -w * 1.00, y: h * 0.16),
            control2: CGPoint(x: -w * 0.72, y: -h * 0.34)
        )
        outline.addCurve(
            to: CGPoint(x: w * 0.64, y: -h * 0.42),
            control1: CGPoint(x: -w * 0.06, y: -h * 0.92),
            control2: CGPoint(x: w * 0.46, y: -h * 0.80)
        )
        outline.addCurve(
            to: CGPoint(x: w * 0.95, y: h * 0.72),
            control1: CGPoint(x: w * 0.88, y: -h * 0.02),
            control2: CGPoint(x: w * 1.03, y: h * 0.36)
        )
        context.stroke(outline, with: .color(Self.inkColor),
                       style: StrokeStyle(lineWidth: inkWidth * 1.05, lineCap: .round, lineJoin: .round))
    }

    private func drawPetals(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let bloomScale = 1.0 + CGFloat(mascot.petalBloom) * 0.085
        for spec in Self.petals {
            let flutter = reduceMotion ? 0.0 : sin(mascot.phase * 1.65 + spec.phaseOffset) * (0.026 + mascot.mouthOpen * 0.055)
            let radians = spec.angleDeg * .pi / 180.0 + flutter
            let len = unit * spec.length * bloomScale
            let wid = unit * spec.width * (1.0 + CGFloat(mascot.petalBloom) * 0.03)
            let baseOffset = unit * 0.46

            context.drawLayer { layer in
                layer.rotate(by: Angle(radians: radians))
                layer.translateBy(x: baseOffset, y: 0)

                // Organic teardrop-oval petal path pointing along +X.
                let skew = spec.tipSkew * wid
                var petal = Path()
                petal.move(to: CGPoint(x: -unit * 0.06, y: 0))
                petal.addCurve(
                    to: CGPoint(x: len, y: skew),
                    control1: CGPoint(x: len * 0.24, y: -wid * 0.92),
                    control2: CGPoint(x: len * 0.98, y: -wid * 0.72 + skew)
                )
                petal.addCurve(
                    to: CGPoint(x: -unit * 0.06, y: 0),
                    control1: CGPoint(x: len * 0.98, y: wid * 0.72 + skew),
                    control2: CGPoint(x: len * 0.24, y: wid * 0.92)
                )
                petal.closeSubpath()

                let grad = Gradient(colors: [Self.petalDeep, Self.petalFill, Self.petalFill])
                layer.fill(petal, with: .linearGradient(grad,
                                                        startPoint: CGPoint(x: 0, y: 0),
                                                        endPoint: CGPoint(x: len, y: 0)))
                layer.stroke(petal, with: .color(Self.inkColor),
                             style: StrokeStyle(lineWidth: inkWidth * 0.95, lineCap: .round, lineJoin: .round))

                // Signature thin hand-drawn inner crease lines near each petal base.
                var creases = Path()
                creases.move(to: CGPoint(x: len * 0.06, y: -wid * 0.09))
                creases.addQuadCurve(to: CGPoint(x: len * 0.38, y: -wid * 0.16),
                                     control: CGPoint(x: len * 0.22, y: -wid * 0.15))
                creases.move(to: CGPoint(x: len * 0.05, y: wid * 0.08))
                creases.addQuadCurve(to: CGPoint(x: len * 0.30, y: wid * 0.14),
                                     control: CGPoint(x: len * 0.18, y: wid * 0.12))
                layer.stroke(creases, with: .color(Self.inkColor.opacity(0.62)),
                             style: StrokeStyle(lineWidth: max(1.0, inkWidth * 0.34), lineCap: .round))
            }
        }
    }

    private func drawFace(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let rx = unit * 0.64
        let ry = unit * 0.56
        let faceRect = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        let facePath = Path(ellipseIn: faceRect)

        // Cream ivory face fill.
        context.fill(facePath, with: .color(Self.faceCream))

        // Green calyx / headband crescent nestled cleanly inside the top rim of the face.
        context.drawLayer { layer in
            layer.clip(to: facePath)
            var band = Path()
            band.move(to: CGPoint(x: -rx * 0.96, y: -ry * 0.34))
            band.addQuadCurve(to: CGPoint(x: rx * 0.96, y: -ry * 0.34),
                              control: CGPoint(x: 0, y: -ry * 0.96))
            band.addLine(to: CGPoint(x: rx * 1.05, y: -ry * 1.12))
            band.addLine(to: CGPoint(x: -rx * 1.05, y: -ry * 1.12))
            band.closeSubpath()
            layer.fill(band, with: .color(Self.leafGreen))

            var bandEdge = Path()
            bandEdge.move(to: CGPoint(x: -rx * 0.96, y: -ry * 0.34))
            bandEdge.addQuadCurve(to: CGPoint(x: rx * 0.96, y: -ry * 0.34),
                                  control: CGPoint(x: 0, y: -ry * 0.96))
            layer.stroke(bandEdge, with: .color(Self.inkColor),
                         style: StrokeStyle(lineWidth: inkWidth * 0.82, lineCap: .round))
        }

        // Crisp hand-drawn outer face outline.
        context.stroke(facePath, with: .color(Self.inkColor),
                       style: StrokeStyle(lineWidth: inkWidth * 1.08, lineCap: .round))
    }

    private func drawEyesAndLashes(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let rx = unit * 0.64
        let ry = unit * 0.56
        let eyeY = -ry * 0.05
        let eyeOffsets: [CGFloat] = [-rx * 0.50, rx * 0.50]
        let eyeR = unit * (0.145 + CGFloat(mascot.clipStartle) * 0.018)
        let blink = mascot.blinkAmount
        let joy = mascot.happyEyes

        for (idx, ex) in eyeOffsets.enumerated() {
            let center = CGPoint(x: ex, y: eyeY)
            let isLeft = idx == 0

            // Joyful closed-arc singing eyes during big passionate notes!
            if joy > 0.65 && mascot.clipStartle < 0.2 {
                var arc = Path()
                arc.move(to: CGPoint(x: center.x - eyeR * 0.92, y: center.y + eyeR * 0.16))
                arc.addQuadCurve(
                    to: CGPoint(x: center.x + eyeR * 0.92, y: center.y + eyeR * 0.16),
                    control: CGPoint(x: center.x, y: center.y - eyeR * 0.88)
                )
                context.stroke(arc, with: .color(Self.inkColor),
                               style: StrokeStyle(lineWidth: inkWidth * 0.95, lineCap: .round))
                drawVerticalLashes(in: &context, center: CGPoint(x: center.x, y: center.y - eyeR * 0.14),
                                   eyeR: eyeR, openScaleY: 0.45, inkWidth: inkWidth, isLeft: isLeft, lengthFactor: 0.72)
                continue
            }

            let openScaleY = max(0.08, 1.0 - CGFloat(blink) * 0.92)
            let eyeRect = CGRect(x: center.x - eyeR, y: center.y - eyeR * openScaleY,
                                 width: eyeR * 2, height: eyeR * 2 * openScaleY)
            let eyePath = Path(ellipseIn: eyeRect)

            // White eye sclera.
            context.fill(eyePath, with: .color(.white))

            // Big dark pupil + crisp specular highlight dot.
            if openScaleY > 0.22 {
                let pupilR = eyeR * (0.64 - CGFloat(mascot.clipStartle) * 0.14)
                let lookY = -CGFloat(mascot.mouthOpen) * eyeR * 0.10
                let pupilCenter = CGPoint(x: center.x + (isLeft ? 0.04 : -0.04) * eyeR, y: center.y + lookY)
                context.drawLayer { layer in
                    layer.clip(to: eyePath)
                    layer.fill(
                        Path(ellipseIn: CGRect(x: pupilCenter.x - pupilR, y: pupilCenter.y - pupilR,
                                               width: pupilR * 2, height: pupilR * 2)),
                        with: .color(Self.inkColor)
                    )
                    // Specular catchlight.
                    let glintR = pupilR * 0.24
                    layer.fill(
                        Path(ellipseIn: CGRect(x: pupilCenter.x - pupilR * 0.34 - glintR,
                                               y: pupilCenter.y - pupilR * 0.34 - glintR,
                                               width: glintR * 2, height: glintR * 2)),
                        with: .color(.white.opacity(0.92))
                    )
                }
            }

            // Crisp eye outline.
            context.stroke(eyePath, with: .color(Self.inkColor),
                           style: StrokeStyle(lineWidth: inkWidth * 0.74, lineCap: .round))

            // Signature tall spiky vertical upper eyelashes anchored to the upper eyelid arc.
            let lashFactor = max(0.35, 1.0 - CGFloat(blink) * 0.55)
            drawVerticalLashes(in: &context, center: center,
                               eyeR: eyeR, openScaleY: openScaleY, inkWidth: inkWidth, isLeft: isLeft, lengthFactor: lashFactor)
        }
    }

    private func drawVerticalLashes(in context: inout GraphicsContext, center: CGPoint, eyeR: CGFloat,
                                    openScaleY: CGFloat, inkWidth: CGFloat, isLeft: Bool, lengthFactor: CGFloat) {
        let count = 7
        var lashes = Path()
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1) // 0...1 across top of eye
            let angle = -.pi * 0.86 + t * (.pi * 0.72)
            let startX = center.x + cos(angle) * eyeR * 0.98
            let startY = center.y + sin(angle) * eyeR * openScaleY * 0.98
            let heightCurve = 0.78 + 0.34 * sin(t * .pi)
            let lashLen = eyeR * 0.92 * heightCurve * lengthFactor
            let tilt = (t - 0.5) * eyeR * 0.32 + (isLeft ? -0.04 : 0.04) * eyeR
            lashes.move(to: CGPoint(x: startX, y: startY))
            lashes.addLine(to: CGPoint(x: startX + tilt, y: startY - lashLen))
        }
        context.stroke(lashes, with: .color(Self.inkColor),
                       style: StrokeStyle(lineWidth: max(1.0, inkWidth * 0.34), lineCap: .round))
    }

    private func drawNoseAndCheeks(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let rx = unit * 0.64
        let ry = unit * 0.56

        // Two tiny nostril dots in the center of the face.
        let dotR = max(1.1, unit * 0.017)
        let noseY = ry * 0.08
        for dx in [-rx * 0.11, rx * 0.11] {
            context.fill(
                Path(ellipseIn: CGRect(x: dx - dotR, y: noseY - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color(Self.inkColor.opacity(0.85))
            )
        }

        // Cute soft pink diagonal cheek blush dashes (brighten gently as singing intensifies).
        let blushAlpha = 0.62 + mascot.mouthOpen * 0.32
        let blushStroke = max(1.4, inkWidth * 0.52)
        var dashes = Path()
        let cheekY = ry * 0.19
        for side in [-1.0, 1.0] as [CGFloat] {
            let baseX = side * rx * 0.74
            for k in -1...1 {
                let cx = baseX + CGFloat(k) * unit * 0.048
                let cy = cheekY + CGFloat(k) * (side < 0 ? -1 : 1) * unit * 0.012
                dashes.move(to: CGPoint(x: cx - unit * 0.016, y: cy + unit * 0.024))
                dashes.addLine(to: CGPoint(x: cx + unit * 0.016, y: cy - unit * 0.024))
            }
        }
        context.stroke(dashes, with: .color(Self.cheekBlush.opacity(blushAlpha)),
                       style: StrokeStyle(lineWidth: blushStroke, lineCap: .round))
    }

    private func drawMouth(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat) {
        let rx = unit * 0.64
        let ry = unit * 0.56
        let open = mascot.mouthOpen
        let startle = mascot.clipStartle
        let mouthY = ry * 0.38

        // Closed / quiet idle: the exact signature wide gentle smile curve!
        if open < 0.045 && startle < 0.15 {
            var smile = Path()
            smile.move(to: CGPoint(x: -rx * 0.56, y: mouthY + ry * 0.01))
            smile.addQuadCurve(
                to: CGPoint(x: rx * 0.58, y: mouthY - ry * 0.08),
                control: CGPoint(x: rx * 0.04, y: mouthY + ry * 0.17)
            )
            context.stroke(smile, with: .color(Self.inkColor),
                           style: StrokeStyle(lineWidth: inkWidth * 0.72, lineCap: .round))
            return
        }

        // Blend 3 unmistakable singing visemes driven by live FFT formant analysis:
        //  - A ("啊"): big tall open D-shaped singing mouth with tongue & upper teeth
        //  - O ("噢/呜"): narrow pursed round circle/oval mouth, no teeth
        //  - E ("咿/诶"): extra-wide cheeky horizontal smile-mouth with bright upper teeth
        let effectiveOpen = max(open, startle * 0.78)
        let clipO = startle * 0.92
        let rawA = mascot.vowelA * (1.0 - clipO)
        let rawO = mascot.vowelO * (1.0 - clipO) + clipO
        let rawE = mascot.vowelE * (1.0 - clipO)
        let norm = max(0.001, rawA + rawO + rawE)
        let wA = CGFloat(rawA / norm)
        let wO = CGFloat(rawO / norm)
        let wE = CGFloat(rawE / norm)
        let o = CGFloat(effectiveOpen)

        // Blended mouth geometry parameters.
        let halfWidth = rx * (
            wA * (0.33 + 0.15 * o) +
            wO * (0.12 + 0.09 * o) +
            wE * (0.45 + 0.13 * o)
        )
        let upperArch = ry * (
            wA * (0.01 + 0.02 * o) +
            wO * (0.09 + 0.15 * o) +
            wE * (-0.06 - 0.03 * o)
        )
        let lowerDrop = ry * (
            wA * (0.15 + 0.45 * o) +
            wO * (0.11 + 0.24 * o) +
            wE * (0.09 + 0.16 * o)
        )
        let topCtrlX = wA * 0.58 + wO * 0.78 + wE * 0.56
        let botCtrlX = wA * 0.84 + wO * 0.78 + wE * 0.90
        let cornerLift = ry * (wE * 0.06 * o - wO * 0.02 * o)

        let cornerY = mouthY - cornerLift - ry * 0.03 * o
        let topPeakY = cornerY - upperArch
        let bottomY = cornerY + lowerDrop
        let totalHeight = max(2.0, bottomY - topPeakY)

        var mouthPath = Path()
        mouthPath.move(to: CGPoint(x: -halfWidth, y: cornerY))
        mouthPath.addCurve(
            to: CGPoint(x: halfWidth, y: cornerY - ry * 0.015 * (1 - wO)),
            control1: CGPoint(x: -halfWidth * topCtrlX, y: topPeakY),
            control2: CGPoint(x: halfWidth * topCtrlX, y: topPeakY)
        )
        mouthPath.addCurve(
            to: CGPoint(x: -halfWidth, y: cornerY),
            control1: CGPoint(x: halfWidth * botCtrlX, y: bottomY),
            control2: CGPoint(x: -halfWidth * botCtrlX, y: bottomY)
        )
        mouthPath.closeSubpath()

        // Dark warm berry interior.
        context.fill(mouthPath, with: .color(Self.mouthInterior))

        // Inside-mouth details tailored to the active vowel shape.
        context.drawLayer { layer in
            layer.clip(to: mouthPath)

            // Cute rosy curved tongue (fullest on "啊", subtle peek on "咿", barely hinted on pursed "噢").
            let tongueVisibility = Double(wA * 1.0 + wE * 0.58 + wO * 0.22)
            if tongueVisibility > 0.12 {
                let tongueW = halfWidth * (1.28 - wO * 0.30)
                let tongueH = totalHeight * (0.64 - wO * 0.22)
                let tongueRect = CGRect(x: -tongueW * 0.5, y: bottomY - tongueH * 0.56,
                                        width: tongueW, height: tongueH)
                layer.fill(Path(ellipseIn: tongueRect),
                           with: .color(Self.tonguePink.opacity(min(1.0, tongueVisibility))))
            }

            // Crisp white upper teeth band (prominent on wide "咿/诶", soft on big "啊", hidden on round "噢").
            let teethVisibility = Double((wE * 1.0 + wA * 0.72) * min(1.0, o * 2.2)) * Double(max(0, 1.0 - wO * 1.45))
            if teethVisibility > 0.12 {
                let teethH = totalHeight * (0.20 + wE * 0.12)
                let teethW = halfWidth * (1.52 + wE * 0.18)
                let teethRect = CGRect(x: -teethW * 0.5, y: topPeakY - teethH * 0.18,
                                       width: teethW, height: teethH)
                layer.fill(Path(roundedRect: teethRect, cornerRadius: teethH * 0.35),
                           with: .color(.white.opacity(0.92 * min(1.0, teethVisibility))))
            }
        }

        // Crisp black hand-drawn mouth outline (slightly bolder on cute pursed O-mouth).
        context.stroke(mouthPath, with: .color(Self.inkColor),
                       style: StrokeStyle(lineWidth: inkWidth * (0.74 + wO * 0.08), lineCap: .round, lineJoin: .round))
    }

    private func drawClipSweatDrop(in context: inout GraphicsContext, unit: CGFloat, inkWidth: CGFloat, opacity: Double) {
        let dropX = unit * 0.56
        let dropY = -unit * 0.34
        let r = unit * 0.08
        var drop = Path()
        drop.move(to: CGPoint(x: dropX, y: dropY - r * 1.6))
        drop.addCurve(
            to: CGPoint(x: dropX, y: dropY + r),
            control1: CGPoint(x: dropX + r * 1.25, y: dropY - r * 0.1),
            control2: CGPoint(x: dropX + r * 0.95, y: dropY + r)
        )
        drop.addCurve(
            to: CGPoint(x: dropX, y: dropY - r * 1.6),
            control1: CGPoint(x: dropX - r * 0.95, y: dropY + r),
            control2: CGPoint(x: dropX - r * 1.25, y: dropY - r * 0.1)
        )
        drop.closeSubpath()
        context.fill(drop, with: .color(Color(red: 0.56, green: 0.84, blue: 1.0).opacity(0.9 * opacity)))
        context.stroke(drop, with: .color(Self.inkColor.opacity(0.85 * opacity)),
                       style: StrokeStyle(lineWidth: max(1.1, inkWidth * 0.42), lineCap: .round, lineJoin: .round))
    }

    private func drawFloatingNotes(in context: inout GraphicsContext, center: CGPoint, unit: CGFloat) {
        guard !mini else { return }
        let colors = [StudioTheme.lyric, StudioTheme.accent, StudioTheme.amber]
        for note in mascot.notes where note.active {
            let p = note.age / note.lifetime
            let alpha = sin(min(1.0, p) * .pi) * 0.88
            let sway = sin(p * .pi * 2.2 + note.phase) * 0.10
            let x = center.x + CGFloat(note.startX + note.driftX * p + sway) * unit * 1.65
            let y = center.y + CGFloat(note.startY - note.rise * p) * unit * 1.65
            let fontSize = max(12, unit * (0.20 + CGFloat(p) * 0.08))
            let color = colors[note.tintIndex % colors.count].opacity(alpha)
            let resolved = context.resolve(
                Text(note.symbol)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            )
            context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }
}
