import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhotoCropRect: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    static let full = PhotoCropRect()
    var isFull: Bool { x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999 }

    var clamped: Self {
        let w = min(1.0, max(0.12, width.isFinite ? width : 1.0))
        let h = min(1.0, max(0.12, height.isFinite ? height : 1.0))
        let cx = min(1.0 - w, max(0.0, x.isFinite ? x : 0.0))
        let cy = min(1.0 - h, max(0.0, y.isFinite ? y : 0.0))
        return Self(x: cx, y: cy, width: w, height: h)
    }

    func cgCropRect(pixelWidth: Int, pixelHeight: Int) -> CGRect {
        let c = clamped
        let pw = CGFloat(pixelWidth)
        let ph = CGFloat(pixelHeight)
        let rx = (c.x * pw).rounded()
        let ry = (c.y * ph).rounded()
        let rw = max(16, min(pw - rx, (c.width * pw).rounded()))
        let rh = max(16, min(ph - ry, (c.height * ph).rounded()))
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }
}

struct PhotoMouthPlacement: Codable, Equatable {
    /// Normalized mouth center inside the rendered (cropped) image rect (0...1).
    var x: Double = 0.5
    var y: Double = 0.65
    /// Normalized mouth size relative to min(imageWidth, imageHeight).
    var scale: Double = 0.24
    /// Rotation angle in degrees (-180...180).
    var rotationDegrees: Double = 0
    /// Optional non-destructive crop rectangle inside the original uploaded image.
    var crop: PhotoCropRect? = nil

    var effectiveCrop: PhotoCropRect { (crop ?? .full).clamped }

    var clamped: Self {
        var angle = rotationDegrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return Self(
            x: min(0.96, max(0.04, x.isFinite ? x : 0.5)),
            y: min(0.96, max(0.04, y.isFinite ? y : 0.65)),
            scale: min(0.65, max(0.06, scale.isFinite ? scale : 0.24)),
            rotationDegrees: angle.isFinite ? angle : 0,
            crop: crop?.clamped
        )
    }

    /// Remaps mouth coordinates and scale from an old crop into a new crop so the mouth stays pinned to the face.
    func remapped(from oldCrop: PhotoCropRect, to newCrop: PhotoCropRect, imageSize: CGSize) -> Self {
        let oldC = oldCrop.clamped
        let newC = newCrop.clamped
        let w = max(1, Double(imageSize.width))
        let h = max(1, Double(imageSize.height))
        let origX = oldC.x + x * oldC.width
        let origY = oldC.y + y * oldC.height
        let oldMin = min(oldC.width * w, oldC.height * h)
        let newMin = max(1, min(newC.width * w, newC.height * h))
        var updated = self
        updated.x = (origX - newC.x) / max(0.01, newC.width)
        updated.y = (origY - newC.y) / max(0.01, newC.height)
        updated.scale = scale * (oldMin / newMin)
        updated.crop = newC.isFull ? nil : newC
        return updated.clamped
    }
}

/// Persists the user's uploaded photo (original + non-destructive crop) and mouth transform in KTake's data directory.
@MainActor
final class PhotoMouthStore: ObservableObject {
    /// Cropped image ready for stage display.
    @Published private(set) var image: NSImage?
    /// Full uncropped source photo for re-cropping in the editor.
    @Published private(set) var originalImage: NSImage?
    @Published var placement = PhotoMouthPlacement()

    private var directory: URL {
        StorageLocations.dataRoot.appendingPathComponent("StagePhoto", isDirectory: true)
    }
    private var originalFileURL: URL { directory.appendingPathComponent("original.png") }
    private var legacyImageFileURL: URL { directory.appendingPathComponent("photo.png") }
    private var configFileURL: URL { directory.appendingPathComponent("placement.json") }

    init() {
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: configFileURL),
           let saved = try? JSONDecoder().decode(PhotoMouthPlacement.self, from: data) {
            placement = saved.clamped
        }
        let sourceURL = FileManager.default.fileExists(atPath: originalFileURL.path) ? originalFileURL : legacyImageFileURL
        if FileManager.default.fileExists(atPath: sourceURL.path),
           let loaded = NSImage(contentsOf: sourceURL) {
            originalImage = loaded
            image = Self.croppedImage(from: loaded, crop: placement.effectiveCrop) ?? loaded
        }
    }

    @discardableResult
    func choosePhoto() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic, .tiff, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "选择一张照片，裁剪并贴上会跟着唱歌的卡通嘴"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return importPhoto(from: url)
    }

    @discardableResult
    func importPhoto(from url: URL) -> Bool {
        guard let loaded = NSImage(contentsOf: url),
              let normalized = Self.bakeOrientedImage(loaded),
              let pngData = Self.pngData(from: normalized) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: originalFileURL, options: .atomic)
            originalImage = normalized
            let reset = PhotoMouthPlacement()
            placement = reset
            image = normalized
            persistPlacement(reset)
            return true
        } catch {
            return false
        }
    }

    func savePlacement(_ value: PhotoMouthPlacement) {
        let clamped = value.clamped
        placement = clamped
        if let originalImage {
            image = Self.croppedImage(from: originalImage, crop: clamped.effectiveCrop) ?? originalImage
        }
        persistPlacement(clamped)
    }

    func clearPhoto() {
        try? FileManager.default.removeItem(at: originalFileURL)
        try? FileManager.default.removeItem(at: legacyImageFileURL)
        originalImage = nil
        image = nil
    }

    static func croppedImage(from source: NSImage, crop: PhotoCropRect) -> NSImage? {
        let clamped = crop.clamped
        if clamped.isFull { return source }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let rect = clamped.cgCropRect(pixelWidth: cg.width, pixelHeight: cg.height)
        guard let sub = cg.cropping(to: rect) else { return source }
        return NSImage(cgImage: sub, size: NSSize(width: sub.width, height: sub.height))
    }

    private func persistPlacement(_ value: PhotoMouthPlacement) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: configFileURL, options: .atomic)
        } catch {}
    }

    /// Re-renders image upright and caps max dimension to 1600px so stage rendering stays crisp & fast.
    private static func bakeOrientedImage(_ source: NSImage) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let maxSide: CGFloat = 1600
        let scale = min(1.0, maxSide / max(width, height))
        let targetSize = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Computes the exact aspect-fit rectangle of an image inside a container so overlay coordinates match everywhere.
func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
        return CGRect(origin: .zero, size: container)
    }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    return CGRect(x: (container.width - w) * 0.5, y: (container.height - h) * 0.5, width: w, height: h)
}

enum MouthPreviewPose: String, CaseIterable, Identifiable {
    case live = "跟麦实时"
    case smile = "微笑"
    case ah = "啊"
    case oh = "噢"
    case ee = "咿"
    var id: String { rawValue }
}

/// Shared vocal mouth animation physics matching FlowerSingerView's exact feel (no @Published churn).
@MainActor
fileprivate final class StandaloneMouthState {
    var mouthOpen: Double = 0
    var vowelA: Double = 0.34
    var vowelO: Double = 0.33
    var vowelE: Double = 0.33
    var energy: Double = 0
    var clipStartle: Double = 0
    var phase: Double = 0
    var lastTime: TimeInterval?
    private var ribbon = Array(repeating: Float(0), count: CaptureBridge.ribbonLength)

    func step(at now: TimeInterval, bridge: CaptureBridge, micEnabled: Bool,
              isPlaying: Bool, pose: MouthPreviewPose, reduceMotion: Bool) {
        let dt: Double
        if let last = lastTime { dt = min(0.05, max(0.001, now - last)) }
        else { dt = 1.0 / 60.0 }
        lastTime = now

        if pose != .live {
            let target: (open: Double, a: Double, o: Double, e: Double)
            switch pose {
            case .smile: target = (0, 0.34, 0.33, 0.33)
            case .ah:    target = (0.82, 0.94, 0.03, 0.03)
            case .oh:    target = (0.78, 0.03, 0.94, 0.03)
            case .ee:    target = (0.72, 0.03, 0.03, 0.94)
            case .live:  target = (0, 0.34, 0.33, 0.33)
            }
            let alpha = 1 - exp(-20.0 * dt)
            mouthOpen += (target.open - mouthOpen) * alpha
            vowelA += (target.a - vowelA) * alpha
            vowelO += (target.o - vowelO) * alpha
            vowelE += (target.e - vowelE) * alpha
            clipStartle = 0
            energy = target.open * 0.5
            return
        }

        let metrics = micEnabled ? bridge.copyStageSignal(into: &ribbon) : StageAudioMetrics()
        let clipping = micEnabled && metrics.clipUntil > ProcessInfo.processInfo.systemUptime

        let targetOpen: Double = (micEnabled && metrics.voiceActive) ? Double(metrics.voiceLevel) : 0
        let targetEnergy: Double = (micEnabled && metrics.voiceActive) ? Double(metrics.energy) : 0

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
        let sum = max(0.001, vowelA + vowelO + vowelE)
        vowelA /= sum
        vowelO /= sum
        vowelE /= sum

        let targetClip: Double = clipping ? 1.0 : 0.0
        clipStartle += (targetClip - clipStartle) * (1 - exp(-(clipping ? 26.0 : 5.0) * dt))
        energy += (targetEnergy - energy) * (1 - exp(-(targetEnergy >= energy ? 12.0 : 6.0) * dt))
        if !reduceMotion {
            phase += dt * (1.2 + (isPlaying ? 1.3 : 0) + mouthOpen * 1.4)
        }
    }
}

/// Standalone animated cartoon mouth with opaque upper & lower lips so it cleanly covers a photo's original mouth.
fileprivate enum CartoonMouthPainter {
    private static let inkColor = Color(red: 0.08, green: 0.06, blue: 0.08)
    private static let upperLipTop = Color(red: 0.90, green: 0.34, blue: 0.44)
    private static let upperLipBottom = Color(red: 0.83, green: 0.27, blue: 0.37)
    private static let lowerLipTop = Color(red: 0.96, green: 0.42, blue: 0.50)
    private static let lowerLipBottom = Color(red: 0.87, green: 0.30, blue: 0.40)
    private static let mouthInterior = Color(red: 0.34, green: 0.08, blue: 0.15)
    private static let tonguePink = Color(red: 0.96, green: 0.49, blue: 0.57)

    static func draw(in context: inout GraphicsContext, center: CGPoint, unit: CGFloat, rotationDegrees: Double,
                     open: Double, vowelA: Double, vowelO: Double, vowelE: Double, clipStartle: Double) {
        let rx = unit * 0.85
        let ry = unit * 0.74
        let inkWidth = max(1.6, unit * 0.078)

        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: Angle(degrees: rotationDegrees))

            // Closed / quiet smile with full opaque cartoon upper & lower lips covering the photo underneath.
            if open < 0.045 && clipStartle < 0.15 {
                let halfW = rx * 0.58
                let leftCorner = CGPoint(x: -halfW, y: ry * 0.01)
                let rightCorner = CGPoint(x: halfW, y: -ry * 0.04)
                let creaseControl = CGPoint(x: rx * 0.02, y: ry * 0.16)

                // Upper lip with cute Cupid's bow.
                var upperLip = Path()
                upperLip.move(to: leftCorner)
                upperLip.addCurve(
                    to: CGPoint(x: 0, y: -ry * 0.15),
                    control1: CGPoint(x: -halfW * 0.62, y: -ry * 0.28),
                    control2: CGPoint(x: -halfW * 0.18, y: -ry * 0.28)
                )
                upperLip.addCurve(
                    to: rightCorner,
                    control1: CGPoint(x: halfW * 0.18, y: -ry * 0.30),
                    control2: CGPoint(x: halfW * 0.62, y: -ry * 0.30)
                )
                upperLip.addQuadCurve(to: leftCorner, control: creaseControl)
                upperLip.closeSubpath()

                // Plump opaque lower lip.
                var lowerLip = Path()
                lowerLip.move(to: leftCorner)
                lowerLip.addQuadCurve(to: rightCorner, control: creaseControl)
                lowerLip.addCurve(
                    to: leftCorner,
                    control1: CGPoint(x: halfW * 0.68, y: ry * 0.38),
                    control2: CGPoint(x: -halfW * 0.68, y: ry * 0.40)
                )
                lowerLip.closeSubpath()

                // Combined outer contour for crisp single-pass outline.
                var outerContour = Path()
                outerContour.move(to: leftCorner)
                outerContour.addCurve(
                    to: CGPoint(x: 0, y: -ry * 0.15),
                    control1: CGPoint(x: -halfW * 0.62, y: -ry * 0.28),
                    control2: CGPoint(x: -halfW * 0.18, y: -ry * 0.28)
                )
                outerContour.addCurve(
                    to: rightCorner,
                    control1: CGPoint(x: halfW * 0.18, y: -ry * 0.30),
                    control2: CGPoint(x: halfW * 0.62, y: -ry * 0.30)
                )
                outerContour.addCurve(
                    to: leftCorner,
                    control1: CGPoint(x: halfW * 0.68, y: ry * 0.38),
                    control2: CGPoint(x: -halfW * 0.68, y: ry * 0.40)
                )
                outerContour.closeSubpath()

                let upperGrad = Gradient(colors: [upperLipTop, upperLipBottom])
                let lowerGrad = Gradient(colors: [lowerLipTop, lowerLipBottom])
                layer.fill(upperLip, with: .linearGradient(upperGrad,
                                                           startPoint: CGPoint(x: 0, y: -ry * 0.28),
                                                           endPoint: CGPoint(x: 0, y: ry * 0.10)))
                layer.fill(lowerLip, with: .linearGradient(lowerGrad,
                                                           startPoint: CGPoint(x: 0, y: ry * 0.05),
                                                           endPoint: CGPoint(x: 0, y: ry * 0.38)))

                // Soft cartoon gloss highlight on lower lip.
                var gloss = Path()
                gloss.move(to: CGPoint(x: -halfW * 0.24, y: ry * 0.22))
                gloss.addQuadCurve(to: CGPoint(x: halfW * 0.28, y: ry * 0.20),
                                   control: CGPoint(x: halfW * 0.02, y: ry * 0.27))
                layer.stroke(gloss, with: .color(.white.opacity(0.36)),
                             style: StrokeStyle(lineWidth: max(1.4, ry * 0.07), lineCap: .round))

                // Outer lip ink outline + crisp closed smile crease.
                layer.stroke(outerContour, with: .color(inkColor),
                             style: StrokeStyle(lineWidth: inkWidth * 0.80, lineCap: .round, lineJoin: .round))
                var smileCrease = Path()
                smileCrease.move(to: leftCorner)
                smileCrease.addQuadCurve(to: rightCorner, control: creaseControl)
                layer.stroke(smileCrease, with: .color(inkColor),
                             style: StrokeStyle(lineWidth: inkWidth * 0.84, lineCap: .round))
                return
            }

            let effectiveOpen = max(open, clipStartle * 0.78)
            let clipO = clipStartle * 0.92
            let rawA = vowelA * (1.0 - clipO)
            let rawO = vowelO * (1.0 - clipO) + clipO
            let rawE = vowelE * (1.0 - clipO)
            let norm = max(0.001, rawA + rawO + rawE)
            let wA = CGFloat(rawA / norm)
            let wO = CGFloat(rawO / norm)
            let wE = CGFloat(rawE / norm)
            let o = CGFloat(effectiveOpen)

            let halfWidth = rx * (
                wA * (0.34 + 0.15 * o) +
                wO * (0.13 + 0.10 * o) +
                wE * (0.45 + 0.13 * o)
            )
            let upperArch = ry * (
                wA * (0.02 + 0.03 * o) +
                wO * (0.11 + 0.16 * o) +
                wE * (-0.06 - 0.03 * o)
            )
            let lowerDrop = ry * (
                wA * (0.16 + 0.46 * o) +
                wO * (0.12 + 0.25 * o) +
                wE * (0.10 + 0.17 * o)
            )
            let topCtrlX = wA * 0.58 + wO * 0.78 + wE * 0.56
            let botCtrlX = wA * 0.84 + wO * 0.78 + wE * 0.90
            let cornerLift = ry * (wE * 0.06 * o - wO * 0.02 * o)

            // Center vertically around (0, 0) so the mouth stays visually anchored on the user's chosen point.
            let rawCornerY = -cornerLift - (lowerDrop - upperArch) * 0.36
            let topPeakY = rawCornerY - upperArch
            let bottomY = rawCornerY + lowerDrop
            let totalHeight = max(2.0, bottomY - topPeakY)

            // 1. Opaque outer cartoon lips wrapping smoothly around the inner singing opening.
            let cornerPadX = rx * (0.09 + wO * 0.07)
            let outerHalfW = halfWidth + cornerPadX
            let upperLipThick = ry * (0.18 + wO * 0.07 - wE * 0.03)
            let lowerLipThick = ry * (0.20 + wO * 0.07 - wE * 0.03)
            let outerLeft = CGPoint(x: -outerHalfW, y: rawCornerY)
            let outerRight = CGPoint(x: outerHalfW, y: rawCornerY - ry * 0.015 * (1 - wO))
            let bowDip = ry * 0.06 * (1 - wO) // Subtle Cupid's bow on A/E, smoothly rounds into plump O-ring on O.
            let outerTopY = topPeakY - upperLipThick
            let outerBottomY = bottomY + lowerLipThick

            var outerLipPath = Path()
            outerLipPath.move(to: outerLeft)
            outerLipPath.addCurve(
                to: CGPoint(x: 0, y: outerTopY + bowDip),
                control1: CGPoint(x: -outerHalfW * (0.72 + wO * 0.14), y: outerTopY - bowDip * 0.7),
                control2: CGPoint(x: -outerHalfW * (0.24 + wO * 0.18), y: outerTopY - bowDip * 0.8)
            )
            outerLipPath.addCurve(
                to: outerRight,
                control1: CGPoint(x: outerHalfW * (0.24 + wO * 0.18), y: outerTopY - bowDip * 0.8),
                control2: CGPoint(x: outerHalfW * (0.72 + wO * 0.14), y: outerTopY - bowDip * 0.7)
            )
            outerLipPath.addCurve(
                to: outerLeft,
                control1: CGPoint(x: outerHalfW * (botCtrlX + 0.04), y: outerBottomY),
                control2: CGPoint(x: -outerHalfW * (botCtrlX + 0.04), y: outerBottomY)
            )
            outerLipPath.closeSubpath()

            let lipGrad = Gradient(colors: [upperLipTop, lowerLipTop, lowerLipBottom])
            layer.fill(outerLipPath, with: .linearGradient(lipGrad,
                                                           startPoint: CGPoint(x: 0, y: outerTopY),
                                                           endPoint: CGPoint(x: 0, y: outerBottomY)))

            // Soft cartoon shine along the lower lip cushion.
            let glossY = bottomY + lowerLipThick * 0.44
            var gloss = Path()
            gloss.move(to: CGPoint(x: -halfWidth * 0.34, y: glossY))
            gloss.addQuadCurve(to: CGPoint(x: halfWidth * 0.34, y: glossY - ry * 0.01),
                               control: CGPoint(x: 0, y: glossY + lowerLipThick * 0.22))
            layer.stroke(gloss, with: .color(.white.opacity(0.32)),
                         style: StrokeStyle(lineWidth: max(1.3, lowerLipThick * 0.28), lineCap: .round))

            layer.stroke(outerLipPath, with: .color(inkColor),
                         style: StrokeStyle(lineWidth: inkWidth * 0.80, lineCap: .round, lineJoin: .round))

            // 2. Inner singing mouth opening (dark berry interior, rosy tongue, white upper teeth).
            var mouthPath = Path()
            mouthPath.move(to: CGPoint(x: -halfWidth, y: rawCornerY))
            mouthPath.addCurve(
                to: CGPoint(x: halfWidth, y: rawCornerY - ry * 0.015 * (1 - wO)),
                control1: CGPoint(x: -halfWidth * topCtrlX, y: topPeakY),
                control2: CGPoint(x: halfWidth * topCtrlX, y: topPeakY)
            )
            mouthPath.addCurve(
                to: CGPoint(x: -halfWidth, y: rawCornerY),
                control1: CGPoint(x: halfWidth * botCtrlX, y: bottomY),
                control2: CGPoint(x: -halfWidth * botCtrlX, y: bottomY)
            )
            mouthPath.closeSubpath()

            layer.fill(mouthPath, with: .color(mouthInterior))

            layer.drawLayer { inner in
                inner.clip(to: mouthPath)

                let tongueVisibility = Double(wA * 1.0 + wE * 0.58 + wO * 0.22)
                if tongueVisibility > 0.12 {
                    let tongueW = halfWidth * (1.28 - wO * 0.30)
                    let tongueH = totalHeight * (0.64 - wO * 0.22)
                    let tongueRect = CGRect(x: -tongueW * 0.5, y: bottomY - tongueH * 0.56,
                                            width: tongueW, height: tongueH)
                    inner.fill(Path(ellipseIn: tongueRect),
                               with: .color(tonguePink.opacity(min(1.0, tongueVisibility))))
                }

                let teethVisibility = Double((wE * 1.0 + wA * 0.72) * min(1.0, o * 2.2)) * Double(max(0, 1.0 - wO * 1.45))
                if teethVisibility > 0.12 {
                    let teethH = totalHeight * (0.21 + wE * 0.12)
                    let teethW = halfWidth * (1.52 + wE * 0.18)
                    let teethRect = CGRect(x: -teethW * 0.5, y: topPeakY - teethH * 0.18,
                                           width: teethW, height: teethH)
                    inner.fill(Path(roundedRect: teethRect, cornerRadius: teethH * 0.35),
                               with: .color(.white.opacity(0.94 * min(1.0, teethVisibility))))
                }
            }

            layer.stroke(mouthPath, with: .color(inkColor),
                         style: StrokeStyle(lineWidth: inkWidth * (0.68 + wO * 0.06), lineCap: .round, lineJoin: .round))
        }
    }
}

/// Live singing photo view: displays the user's photo with the animated cartoon mouth overlaid at the chosen position.
struct PhotoMouthSingerView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var store: PhotoMouthStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mini: Bool
    let focusStage: Bool
    let openEditor: () -> Void
    let pickPhoto: () -> Void
    @State private var mouthState = StandaloneMouthState()
    @State private var hovered = false

    private var shouldAnimate: Bool {
        !reduceMotion || model.microphoneEnabled
    }

    var body: some View {
        if let image = store.image {
            GeometryReader { geo in
                let pad: CGFloat = mini ? 4 : 12
                let available = CGSize(width: max(1, geo.size.width - pad * 2),
                                       height: max(1, geo.size.height - pad * 2))
                let fitted = aspectFitRect(imageSize: image.size, in: available)
                let frameRect = fitted.offsetBy(dx: pad, dy: pad)
                let radius: CGFloat = mini ? 14 : 20

                ZStack {
                    // Ambient stage card glow behind the photo.
                    if !mini {
                        RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                            .fill(StudioTheme.accent.opacity(0.14))
                            .blur(radius: 22)
                            .frame(width: frameRect.width * 0.92, height: frameRect.height * 0.92)
                            .position(x: frameRect.midX, y: frameRect.midY)
                            .allowsHitTesting(false)
                    }

                    // Photo surface + animated cartoon mouth tightly coupled in exact image coordinates.
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: frameRect.width, height: frameRect.height)

                        TimelineView(.animation(minimumInterval: nil, paused: !shouldAnimate)) { timeline in
                            Canvas { context, size in
                                let now = timeline.date.timeIntervalSinceReferenceDate
                                mouthState.step(at: now, bridge: model.audio.bridge,
                                                micEnabled: model.microphoneEnabled,
                                                isPlaying: model.isPlaying,
                                                pose: .live,
                                                reduceMotion: reduceMotion)
                                let p = store.placement
                                let mouthCenter = CGPoint(x: size.width * p.x, y: size.height * p.y)
                                let mouthUnit = min(size.width, size.height) * p.scale
                                CartoonMouthPainter.draw(
                                    in: &context,
                                    center: mouthCenter,
                                    unit: mouthUnit,
                                    rotationDegrees: p.rotationDegrees,
                                    open: mouthState.mouthOpen,
                                    vowelA: mouthState.vowelA,
                                    vowelO: mouthState.vowelO,
                                    vowelE: mouthState.vowelE,
                                    clipStartle: mouthState.clipStartle
                                )
                            }
                        }
                        .frame(width: frameRect.width, height: frameRect.height)
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(mini ? 0.18 : 0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: mini ? 8 : 18, x: 0, y: mini ? 4 : 8)
                    .position(x: frameRect.midX, y: frameRect.midY)
                    .overlay {
                        if !mini {
                            photoControlsOverlay(frameRect: frameRect)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
            }
            .overlay(alignment: .bottom) {
                if !mini && !model.microphoneEnabled {
                    Text("启用麦克风后，照片上的嘴会跟着歌声开口")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial.opacity(0.45), in: Capsule())
                        .overlay { Capsule().strokeBorder(StudioTheme.separator) }
                        .padding(.bottom, 2)
                        .allowsHitTesting(false)
                }
            }
        } else if !mini {
            emptyPhotoCard
        }
    }

    private func photoControlsOverlay(frameRect: CGRect) -> some View {
        HStack(spacing: 6) {
            Button(action: openEditor) {
                Label("裁剪 / 嘴型", systemImage: "crop")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.64), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.18)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("裁剪照片并拖动、缩放或旋转嘴部位置")

            Button(action: pickPhoto) {
                Label("换照片", systemImage: "photo")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.64), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.18)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("上传新照片")
        }
        .position(x: frameRect.midX, y: frameRect.maxY - 22)
        .opacity(hovered ? 1 : 0.0)
        .animation(reduceMotion ? nil : StudioTheme.quick, value: hovered)
    }

    private var emptyPhotoCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(StudioTheme.accent.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(StudioTheme.action)
            }
            VStack(spacing: 4) {
                Text("上传照片，给它长一张会唱歌的嘴")
                    .font(.system(size: focusStage ? 18 : 15, weight: .semibold, design: .rounded))
                Text("支持 PNG / JPG / HEIC，上传后可自由拖动、缩放和旋转嘴型位置")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: pickPhoto) {
                Label("选择照片…", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 32)
            }
            .buttonStyle(StudioActionStyle(emphasis: .primary))
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(StudioTheme.inset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(StudioTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .padding(.horizontal, 24)
    }
}

/// Interactive editor sheet supporting both non-destructive photo cropping and drag/scale/rotate mouth placement.
struct PhotoMouthEditorSheet: View {
    private enum EditorTab: String, CaseIterable, Identifiable {
        case crop = "裁剪照片"
        case mouth = "调整嘴型"
        var id: String { rawValue }
    }

    private enum CropAspect: String, CaseIterable, Identifiable {
        case free = "自由"
        case square = "1:1"
        case landscape43 = "4:3"
        case portrait34 = "3:4"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .free: nil
            case .square: 1.0
            case .landscape43: 4.0 / 3.0
            case .portrait34: 3.0 / 4.0
            }
        }
    }

    private enum CropCorner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SessionModel
    @ObservedObject var store: PhotoMouthStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: EditorTab = .mouth
    @State private var cropAspect: CropAspect = .free
    @State private var draft: PhotoMouthPlacement
    @State private var draftCrop: PhotoCropRect
    @State private var croppedPreview: NSImage?
    @State private var previewPose: MouthPreviewPose
    @State private var dragStart: PhotoMouthPlacement?
    @State private var scaleStart: (scale: Double, distance: CGFloat)?
    @State private var cropDragStart: PhotoCropRect?
    @State private var mouthState = StandaloneMouthState()

    init(model: SessionModel, store: PhotoMouthStore, startInCrop: Bool = false) {
        self.model = model
        self.store = store
        _tab = State(initialValue: startInCrop ? .crop : .mouth)
        _draft = State(initialValue: store.placement)
        _draftCrop = State(initialValue: store.placement.effectiveCrop)
        _croppedPreview = State(initialValue: store.image)
        _previewPose = State(initialValue: model.microphoneEnabled ? .live : .ah)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab == .crop ? "裁剪舞台照片" : "调整嘴部位置").font(.title2.bold())
                    Text(tab == .crop
                         ? "拖动四个角调整裁剪范围，拖动框内平移画面"
                         : "拖动嘴部移动位置，拖右下角圆点缩放，拖上方圆点旋转")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("编辑步骤", selection: $tab) {
                    ForEach(EditorTab.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 176)
                Button {
                    if store.choosePhoto() {
                        draft = PhotoMouthPlacement()
                        draftCrop = .full
                        cropAspect = .free
                        rebuildCroppedPreview()
                    }
                } label: {
                    Label("更换照片…", systemImage: "photo")
                }
            }

            Group {
                if tab == .crop {
                    cropCanvas
                } else {
                    mouthCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioTheme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StudioTheme.separator)
            }

            if tab == .crop {
                cropControls
            } else {
                mouthControls
            }

            Divider()

            HStack {
                if tab == .crop {
                    Button("还原整图") {
                        applyCropChange(.full)
                        cropAspect = .free
                    }
                    .disabled(draftCrop.isFull)
                } else {
                    Button("重置嘴型") {
                        var reset = PhotoMouthPlacement()
                        reset.crop = draftCrop.isFull ? nil : draftCrop
                        draft = reset
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if tab == .crop {
                    Button("下一步：调嘴型") {
                        rebuildCroppedPreview()
                        tab = .mouth
                    }
                }
                Button("保存") {
                    var finalPlacement = draft
                    finalPlacement.crop = draftCrop.isFull ? nil : draftCrop.clamped
                    store.savePlacement(finalPlacement)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 660)
        .studioSheet()
        .onChange(of: tab) { _, newTab in
            if newTab == .mouth { rebuildCroppedPreview() }
        }
        .onAppear {
            rebuildCroppedPreview()
        }
    }

    private var cropControls: some View {
        HStack(spacing: 12) {
            Text("裁剪比例").font(.callout).frame(width: 64, alignment: .leading)
            Picker("裁剪比例", selection: $cropAspect) {
                ForEach(CropAspect.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: cropAspect) { _, aspect in
                guard let targetRatio = aspect.ratio, let orig = store.originalImage else { return }
                snapCrop(toAspect: targetRatio, imageSize: orig.size)
            }
            Spacer()
            if let orig = store.originalImage {
                let cw = Int((orig.size.width * draftCrop.width).rounded())
                let ch = Int((orig.size.height * draftCrop.height).rounded())
                Text("\(cw) × \(ch)")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 36)
    }

    private var mouthControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("口型预览").font(.callout).frame(width: 60, alignment: .leading)
                Picker("口型预览", selection: $previewPose) {
                    ForEach(MouthPreviewPose.allCases) { pose in
                        Text(pose.rawValue).tag(pose)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 12) {
                Text("大小").font(.callout).frame(width: 60, alignment: .leading)
                Slider(value: $draft.scale, in: 0.06...0.65)
                Text("\(Int((draft.scale * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Text("旋转").font(.callout).frame(width: 60, alignment: .leading)
                Slider(value: $draft.rotationDegrees, in: -180...180)
                Text(String(format: "%+.0f°", draft.rotationDegrees))
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                Button("归零") { draft.rotationDegrees = 0 }
                    .disabled(abs(draft.rotationDegrees) < 0.5)
            }
        }
    }

    private func applyCropChange(_ newCrop: PhotoCropRect) {
        let clamped = newCrop.clamped
        if let orig = store.originalImage {
            draft = draft.remapped(from: draftCrop, to: clamped, imageSize: orig.size)
        } else {
            draft.crop = clamped.isFull ? nil : clamped
        }
        draftCrop = clamped
    }

    private func snapCrop(toAspect targetRatio: CGFloat, imageSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let imgAspect = imageSize.width / imageSize.height
        // Normalized width / height ratio needed to achieve pixel aspect ratio `targetRatio`.
        let normRatio = Double(targetRatio / imgAspect)
        let centerX = draftCrop.x + draftCrop.width * 0.5
        let centerY = draftCrop.y + draftCrop.height * 0.5
        var newW = draftCrop.width
        var newH = newW / normRatio
        if newH > 1.0 {
            newH = 1.0
            newW = newH * normRatio
        }
        if newW > 1.0 {
            newW = 1.0
            newH = newW / normRatio
        }
        newW = max(0.15, min(1.0, newW))
        newH = max(0.15, min(1.0, newH))
        let nx = min(1.0 - newW, max(0.0, centerX - newW * 0.5))
        let ny = min(1.0 - newH, max(0.0, centerY - newH * 0.5))
        applyCropChange(PhotoCropRect(x: nx, y: ny, width: newW, height: newH))
    }

    private func rebuildCroppedPreview() {
        guard let orig = store.originalImage else { croppedPreview = store.image; return }
        croppedPreview = PhotoMouthStore.croppedImage(from: orig, crop: draftCrop) ?? orig
    }

    private var cropCanvas: some View {
        GeometryReader { geo in
            if let orig = store.originalImage {
                let pad: CGFloat = 20
                let available = CGSize(width: max(1, geo.size.width - pad * 2),
                                       height: max(1, geo.size.height - pad * 2))
                let fitted = aspectFitRect(imageSize: orig.size, in: available)
                let imageRect = fitted.offsetBy(dx: pad, dy: pad)
                let cropBox = CGRect(
                    x: imageRect.minX + imageRect.width * draftCrop.x,
                    y: imageRect.minY + imageRect.height * draftCrop.y,
                    width: imageRect.width * draftCrop.width,
                    height: imageRect.height * draftCrop.height
                )

                ZStack {
                    Image(nsImage: orig)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    // Dark translucent vignette outside the crop box.
                    Path { path in
                        path.addRect(imageRect)
                        path.addRect(cropBox)
                    }
                    .fill(Color.black.opacity(0.60), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    // Subtle ghost indicator of where the mouth sits inside the crop box.
                    let ghostCenter = CGPoint(
                        x: cropBox.minX + cropBox.width * draft.x,
                        y: cropBox.minY + cropBox.height * draft.y
                    )
                    let ghostUnit = min(cropBox.width, cropBox.height) * draft.scale
                    Canvas { context, _ in
                        CartoonMouthPainter.draw(
                            in: &context,
                            center: ghostCenter,
                            unit: ghostUnit,
                            rotationDegrees: draft.rotationDegrees,
                            open: 0,
                            vowelA: 0.34, vowelO: 0.33, vowelE: 0.33,
                            clipStartle: 0
                        )
                    }
                    .opacity(0.55)
                    .allowsHitTesting(false)

                    // Rule-of-thirds guide lines + crisp border + pan gesture inside crop box.
                    ZStack {
                        Path { path in
                            let w = cropBox.width, h = cropBox.height
                            path.move(to: CGPoint(x: w / 3, y: 0)); path.addLine(to: CGPoint(x: w / 3, y: h))
                            path.move(to: CGPoint(x: w * 2 / 3, y: 0)); path.addLine(to: CGPoint(x: w * 2 / 3, y: h))
                            path.move(to: CGPoint(x: 0, y: h / 3)); path.addLine(to: CGPoint(x: w, y: h / 3))
                            path.move(to: CGPoint(x: 0, y: h * 2 / 3)); path.addLine(to: CGPoint(x: w, y: h * 2 / 3))
                        }
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)

                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.8)
                    }
                    .frame(width: cropBox.width, height: cropBox.height)
                    .contentShape(Rectangle())
                    .position(x: cropBox.midX, y: cropBox.midY)
                    .gesture(
                        DragGesture(coordinateSpace: .named("photoCropCanvas"))
                            .onChanged { value in
                                let start = cropDragStart ?? draftCrop
                                if cropDragStart == nil { cropDragStart = draftCrop }
                                let dx = value.translation.width / max(1, imageRect.width)
                                let dy = value.translation.height / max(1, imageRect.height)
                                let nx = min(1.0 - start.width, max(0.0, start.x + dx))
                                let ny = min(1.0 - start.height, max(0.0, start.y + dy))
                                applyCropChange(PhotoCropRect(x: nx, y: ny, width: start.width, height: start.height))
                            }
                            .onEnded { _ in cropDragStart = nil }
                    )

                    // 4 draggable corner handles for resizing the crop rectangle.
                    ForEach(CropCorner.allCases, id: \.self) { corner in
                        let pos = cornerPoint(corner, in: cropBox)
                        Circle()
                            .fill(StudioTheme.accent)
                            .frame(width: 18, height: 18)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                            .position(pos)
                            .gesture(
                                DragGesture(coordinateSpace: .named("photoCropCanvas"))
                                    .onChanged { value in
                                        let start = cropDragStart ?? draftCrop
                                        if cropDragStart == nil { cropDragStart = draftCrop }
                                        let resized = resizeCrop(from: start, corner: corner,
                                                                 translation: value.translation,
                                                                 imageRect: imageRect,
                                                                 imageSize: orig.size)
                                        applyCropChange(resized)
                                    }
                                    .onEnded { _ in cropDragStart = nil }
                            )
                    }
                }
                .coordinateSpace(name: "photoCropCanvas")
            } else {
                emptyEditorPlaceholder
            }
        }
    }

    private func cornerPoint(_ corner: CropCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func resizeCrop(from start: PhotoCropRect, corner: CropCorner, translation: CGSize,
                            imageRect: CGRect, imageSize: CGSize) -> PhotoCropRect {
        let minSize = 0.14
        let dx = Double(translation.width / max(1, imageRect.width))
        let dy = Double(translation.height / max(1, imageRect.height))
        let startRight = start.x + start.width
        let startBottom = start.y + start.height

        var left = start.x
        var right = startRight
        var top = start.y
        var bottom = startBottom

        switch corner {
        case .topLeft:
            left = min(startRight - minSize, max(0, start.x + dx))
            top = min(startBottom - minSize, max(0, start.y + dy))
        case .topRight:
            right = max(start.x + minSize, min(1, startRight + dx))
            top = min(startBottom - minSize, max(0, start.y + dy))
        case .bottomLeft:
            left = min(startRight - minSize, max(0, start.x + dx))
            bottom = max(start.y + minSize, min(1, startBottom + dy))
        case .bottomRight:
            right = max(start.x + minSize, min(1, startRight + dx))
            bottom = max(start.y + minSize, min(1, startBottom + dy))
        }

        var w = right - left
        var h = bottom - top

        if let targetRatio = cropAspect.ratio, imageSize.width > 0, imageSize.height > 0 {
            let normRatio = Double(targetRatio / (imageSize.width / imageSize.height))
            // Keep opposite corner anchored while enforcing aspect ratio.
            let maxW: Double
            let maxH: Double
            switch corner {
            case .topLeft:     maxW = startRight; maxH = startBottom
            case .topRight:    maxW = 1 - start.x; maxH = startBottom
            case .bottomLeft:  maxW = startRight; maxH = 1 - start.y
            case .bottomRight: maxW = 1 - start.x; maxH = 1 - start.y
            }
            h = w / normRatio
            if h > maxH {
                h = maxH
                w = h * normRatio
            }
            if w > maxW {
                w = maxW
                h = w / normRatio
            }
            w = max(minSize, w)
            h = max(minSize, h)
            switch corner {
            case .topLeft:     left = startRight - w; top = startBottom - h
            case .topRight:    top = startBottom - h
            case .bottomLeft:  left = startRight - w
            case .bottomRight: break
            }
        }

        return PhotoCropRect(x: left, y: top, width: w, height: h).clamped
    }

    private var mouthCanvas: some View {
        GeometryReader { geo in
            if let image = croppedPreview ?? store.image {
                let pad: CGFloat = 18
                let available = CGSize(width: max(1, geo.size.width - pad * 2),
                                       height: max(1, geo.size.height - pad * 2))
                let fitted = aspectFitRect(imageSize: image.size, in: available)
                let imageRect = fitted.offsetBy(dx: pad, dy: pad)
                let mouthCenter = CGPoint(
                    x: imageRect.minX + imageRect.width * draft.x,
                    y: imageRect.minY + imageRect.height * draft.y
                )
                let mouthUnit = min(imageRect.width, imageRect.height) * draft.scale
                let boxHalfW = max(24, mouthUnit * 0.58)
                let boxHalfH = max(20, mouthUnit * 0.48)
                let rad = draft.rotationDegrees * .pi / 180.0
                let cosA = CGFloat(cos(rad))
                let sinA = CGFloat(sin(rad))

                let rotateOffset = CGPoint(x: 0, y: -(boxHalfH + 26))
                let rotateHandlePos = CGPoint(
                    x: mouthCenter.x + rotateOffset.x * cosA - rotateOffset.y * sinA,
                    y: mouthCenter.y + rotateOffset.x * sinA + rotateOffset.y * cosA
                )
                let scaleOffset = CGPoint(x: boxHalfW, y: boxHalfH)
                let scaleHandlePos = CGPoint(
                    x: mouthCenter.x + scaleOffset.x * cosA - scaleOffset.y * sinA,
                    y: mouthCenter.y + scaleOffset.x * sinA + scaleOffset.y * cosA
                )

                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .position(x: imageRect.midX, y: imageRect.midY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("photoEditorCanvas"))
                                .onChanged { value in
                                    let nx = (value.location.x - imageRect.minX) / max(1, imageRect.width)
                                    let ny = (value.location.y - imageRect.minY) / max(1, imageRect.height)
                                    draft.x = min(0.96, max(0.04, nx))
                                    draft.y = min(0.96, max(0.04, ny))
                                }
                        )

                    TimelineView(.animation(minimumInterval: nil, paused: reduceMotion && previewPose == .live && !model.microphoneEnabled)) { timeline in
                        Canvas { context, _ in
                            let now = timeline.date.timeIntervalSinceReferenceDate
                            mouthState.step(at: now, bridge: model.audio.bridge,
                                            micEnabled: model.microphoneEnabled,
                                            isPlaying: model.isPlaying,
                                            pose: previewPose,
                                            reduceMotion: reduceMotion)
                            CartoonMouthPainter.draw(
                                in: &context,
                                center: mouthCenter,
                                unit: mouthUnit,
                                rotationDegrees: draft.rotationDegrees,
                                open: mouthState.mouthOpen,
                                vowelA: mouthState.vowelA,
                                vowelO: mouthState.vowelO,
                                vowelE: mouthState.vowelE,
                                clipStartle: mouthState.clipStartle
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(StudioTheme.accent.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(width: boxHalfW * 2, height: boxHalfH * 2)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: -boxHalfH))
                            path.addLine(to: CGPoint(x: 0, y: -(boxHalfH + 22)))
                        }
                        .stroke(StudioTheme.accent.opacity(0.75), lineWidth: 1.5)
                        .frame(width: 2, height: 2)
                    }
                    .frame(width: boxHalfW * 2, height: boxHalfH * 2)
                    .contentShape(Rectangle())
                    .rotationEffect(.degrees(draft.rotationDegrees))
                    .position(mouthCenter)
                    .gesture(
                        DragGesture(coordinateSpace: .named("photoEditorCanvas"))
                            .onChanged { value in
                                let start = dragStart ?? draft
                                if dragStart == nil { dragStart = draft }
                                let nx = start.x + value.translation.width / max(1, imageRect.width)
                                let ny = start.y + value.translation.height / max(1, imageRect.height)
                                draft.x = min(0.96, max(0.04, nx))
                                draft.y = min(0.96, max(0.04, ny))
                            }
                            .onEnded { _ in dragStart = nil }
                    )

                    handleKnob(systemImage: "arrow.triangle.2.circlepath", fill: StudioTheme.lavender)
                        .position(rotateHandlePos)
                        .gesture(
                            DragGesture(coordinateSpace: .named("photoEditorCanvas"))
                                .onChanged { value in
                                    let dx = value.location.x - mouthCenter.x
                                    let dy = value.location.y - mouthCenter.y
                                    var deg = atan2(dy, dx) * 180.0 / .pi + 90.0
                                    if deg > 180 { deg -= 360 }
                                    if deg < -180 { deg += 360 }
                                    draft.rotationDegrees = abs(deg) < 3.0 ? 0 : deg
                                }
                        )
                        .help("拖动旋转嘴型")

                    handleKnob(systemImage: "arrow.up.left.and.arrow.down.right", fill: StudioTheme.accent)
                        .position(scaleHandlePos)
                        .gesture(
                            DragGesture(coordinateSpace: .named("photoEditorCanvas"))
                                .onChanged { value in
                                    let dist = max(12, hypot(value.location.x - mouthCenter.x, value.location.y - mouthCenter.y))
                                    if scaleStart == nil {
                                        scaleStart = (draft.scale, max(18, hypot(boxHalfW, boxHalfH)))
                                    }
                                    if let start = scaleStart {
                                        let ratio = Double(dist / start.distance)
                                        draft.scale = min(0.65, max(0.06, start.scale * ratio))
                                    }
                                }
                                .onEnded { _ in scaleStart = nil }
                        )
                        .help("拖动缩放嘴型大小")
                }
                .coordinateSpace(name: "photoEditorCanvas")
            } else {
                emptyEditorPlaceholder
            }
        }
    }

    private var emptyEditorPlaceholder: some View {
        VStack(spacing: 12) {
            Text("还没有选择照片").foregroundStyle(.secondary)
            Button("选择照片…") {
                if store.choosePhoto() {
                    draft = PhotoMouthPlacement()
                    draftCrop = .full
                    rebuildCroppedPreview()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleKnob(systemImage: String, fill: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(StudioTheme.canvas)
            .frame(width: 24, height: 24)
            .background(fill, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
    }
}
