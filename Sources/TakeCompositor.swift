@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct VideoSpan: Sendable {
    let clip: TimelineClip
    let transform: CGAffineTransform
    var motion: MotionEffects?
    var drawsCursor = false
}

final class TakeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let screenID: CMPersistentTrackID?
    let cameraID: CMPersistentTrackID?
    let screens: [VideoSpan]
    let cameras: [VideoSpan]
    let settings: EffectSettings
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let enablePostProcessing = true
    let containsTweening = true

    var requiredSourceTrackIDs: [NSValue]? {
        let visible = [screens.isEmpty ? nil : screenID, cameras.isEmpty ? nil : cameraID].compactMap { $0 }
        let required = visible.isEmpty ? [screenID ?? cameraID].compactMap { $0 } : visible
        return required.map { NSNumber(value: $0) }
    }

    init(timeRange: CMTimeRange, screenID: CMPersistentTrackID?, cameraID: CMPersistentTrackID?,
         screens: [VideoSpan], cameras: [VideoSpan], settings: EffectSettings) {
        self.timeRange = timeRange
        self.screenID = screenID
        self.cameraID = cameraID
        self.screens = screens
        self.cameras = cameras
        self.settings = settings
    }

    func screen(at time: Double) -> VideoSpan? { span(in: screens, at: time) }
    func camera(at time: Double) -> VideoSpan? { span(in: cameras, at: time) }

    private func span(in spans: [VideoSpan], at time: Double) -> VideoSpan? {
        var left = 0
        var right = spans.count
        while left < right {
            let middle = (left + right) / 2
            if spans[middle].clip.at <= time { left = middle + 1 }
            else { right = middle }
        }
        guard left > 0, spans[left - 1].clip.contains(time) else { return nil }
        return spans[left - 1]
    }
}

final class TakeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TakeInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: RecorderError.message("无法分配预览画面。"))
            return
        }
        let canvas = CGRect(origin: .zero, size: request.renderContext.size)
        let time = request.compositionTime.seconds
        let screen = instruction.screen(at: time)
        let effect = screen?.motion?.frame(at: time) ?? MotionEffects.Frame()
        let settings = instruction.settings
        let pan = effect.pan(in: canvas)
        var result = CIImage(color: .black).cropped(to: canvas)
        if let screen, let id = instruction.screenID, let source = request.sourceFrame(byTrackID: id) {
            result = fit(oriented(source, transform: screen.transform), in: canvas, fill: false)
                .composited(over: result).transformed(by: pan).cropped(to: canvas)
        }
        if effect.blur > 0.1 {
            result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: effect.blur
            ]).cropped(to: canvas)
        }
        let cursorUnit = max(19, min(canvas.width, canvas.height) * 0.045)
        for ripple in effect.ripples.suffix(8) {
            let point = CGPoint(x: ripple.point.x * canvas.width, y: (1 - ripple.point.y) * canvas.height).applying(pan)
            let side = cursorUnit * (0.85 + 2.7 * ripple.progress)
            let ring = Self.ring.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: pow(1 - ripple.progress, 0.72))
            ])
            result = sprite(ring, at: point, hotspot: CGPoint(x: 32, y: 32), side: side)
                .composited(over: result)
        }
        if screen?.drawsCursor == true, settings.cursor != .hidden {
            for (index, point) in effect.trail.enumerated() {
                let position = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height).applying(pan)
                let dot = Self.dot.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.17 + 0.10 * Double(index))
                ])
                result = sprite(dot, at: position, hotspot: CGPoint(x: 32, y: 32), side: cursorUnit * 0.64)
                    .composited(over: result)
            }
        }
        if screen?.drawsCursor == true, let point = effect.cursor, let glyph = Self.glyph(settings.cursor) {
            let hotspot = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height).applying(pan)
            result = sprite(glyph.0, at: hotspot, hotspot: glyph.1,
                            side: cursorUnit * clamp(settings.cursorSize, 0.5, 3)).composited(over: result)
        }
        if let span = instruction.camera(at: time), let id = instruction.cameraID,
           let camera = request.sourceFrame(byTrackID: id) {
            result = cameraOverlay(oriented(camera, transform: span.transform), on: result,
                                   canvas: canvas, settings: settings)
        }
        context.render(result.cropped(to: canvas), to: output, bounds: canvas, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    private func oriented(_ buffer: CVPixelBuffer, transform: CGAffineTransform) -> CIImage {
        let orientation = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d,
                                            tx: 0, ty: 0)
        return CIImage(cvPixelBuffer: buffer).transformed(by: orientation)
    }

    private func fit(_ image: CIImage, in bounds: CGRect, fill: Bool) -> CIImage {
        let x = bounds.width / image.extent.width
        let y = bounds.height / image.extent.height
        let scale = fill ? max(x, y) : min(x, y)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: bounds.midX - scaled.extent.midX,
                                                        y: bounds.midY - scaled.extent.midY)).cropped(to: bounds)
    }

    private func sprite(_ image: CIImage, at position: CGPoint, hotspot: CGPoint, side: CGFloat) -> CIImage {
        let scale = side / 64
        return image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                        tx: position.x - hotspot.x * scale,
                                                        ty: position.y - hotspot.y * scale))
    }

    private func cameraOverlay(_ camera: CIImage, on background: CIImage, canvas: CGRect, settings: EffectSettings) -> CIImage {
        let side = min(canvas.width, canvas.height) * clamp(settings.cameraSize, 0.12, 0.55)
        let margin = min(canvas.width, canvas.height) * 0.032
        let right = settings.cameraCorner == .topRight || settings.cameraCorner == .bottomRight
        let top = settings.cameraCorner == .topRight || settings.cameraCorner == .topLeft
        let box = CGRect(x: right ? canvas.maxX - margin - side : margin,
                         y: top ? canvas.maxY - margin - side : margin, width: side, height: side)
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = box
        shape.radius = Float(side * (settings.cameraShape == .circle ? 0.5 : 0.18))
        shape.color = .white
        let mask = shape.outputImage ?? CIImage(color: .white).cropped(to: box)
        let adjusted = settings.portraitLighting?.apply(to: camera) ?? camera
        let fitted = fit(adjusted, in: box, fill: true)
        let subject = settings.cameraMirrored
            ? fitted.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: box.midX * 2, ty: 0))
            : fitted
        return subject.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask
        ])
    }

    static func glyph(_ style: CursorStyle) -> (CIImage, CGPoint)? {
        switch style {
        case .arrow: (arrow, CGPoint(x: 10, y: 55))
        case .darkArrow: (darkArrow, CGPoint(x: 10, y: 55))
        case .dot: (dot, CGPoint(x: 32, y: 32))
        case .ring: (outlineRing, CGPoint(x: 32, y: 32))
        case .crosshair: (crosshair, CGPoint(x: 32, y: 32))
        case .hand: (hand, CGPoint(x: 25, y: 56))
        case .hidden: nil
        }
    }

    private static func paint(_ draw: (CGContext) -> Void) -> CIImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return CIImage(cgImage: context.makeImage()!)
    }

    private static let arrow = makeArrow(light: true)
    private static let darkArrow = makeArrow(light: false)

    private static func makeArrow(light: Bool) -> CIImage { paint { context in
        let points = [CGPoint(x: 10, y: 55), CGPoint(x: 11, y: 13), CGPoint(x: 22, y: 23),
                      CGPoint(x: 30, y: 8), CGPoint(x: 38, y: 12), CGPoint(x: 30, y: 28),
                      CGPoint(x: 45, y: 30)]
        context.addLines(between: points)
        context.closePath()
        context.setLineJoin(.round)
        context.setLineWidth(4)
        context.setFillColor(gray: light ? 1 : 0.10, alpha: 1)
        context.setStrokeColor(gray: light ? 0 : 1, alpha: 0.9)
        context.drawPath(using: .fillStroke)
    } }

    private static let hand = paint { context in
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: 8))
        path.addQuadCurve(to: CGPoint(x: 8, y: 27), control: CGPoint(x: 7, y: 17))
        path.addQuadCurve(to: CGPoint(x: 19, y: 28), control: CGPoint(x: 10, y: 36))
        path.addLine(to: CGPoint(x: 20, y: 51))
        path.addQuadCurve(to: CGPoint(x: 30, y: 51), control: CGPoint(x: 25, y: 61))
        path.addLine(to: CGPoint(x: 31, y: 36))
        path.addQuadCurve(to: CGPoint(x: 51, y: 32), control: CGPoint(x: 50, y: 42))
        path.addQuadCurve(to: CGPoint(x: 45, y: 8), control: CGPoint(x: 56, y: 19))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 0.08, alpha: 1)
        context.setLineJoin(.round)
        context.setLineWidth(3.5)
        context.drawPath(using: .fillStroke)
    }

    private static let outlineRing = paint { context in
        for (width, gray) in [(8.0, 0.05), (4.0, 1.0)] {
            context.setLineWidth(width)
            context.setStrokeColor(gray: gray, alpha: 1)
            context.strokeEllipse(in: CGRect(x: 13, y: 13, width: 38, height: 38))
        }
    }

    private static let dot = paint { context in
        context.setFillColor(red: 1, green: 0.35, blue: 0.18, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(4)
        context.addEllipse(in: CGRect(x: 18, y: 18, width: 28, height: 28))
        context.drawPath(using: .fillStroke)
    }

    private static let crosshair = paint { context in
        for (width, gray) in [(8.0, 0.0), (4.0, 1.0)] {
            context.setStrokeColor(gray: gray, alpha: 1)
            context.setLineWidth(width)
            context.move(to: CGPoint(x: 13, y: 32))
            context.addLine(to: CGPoint(x: 51, y: 32))
            context.move(to: CGPoint(x: 32, y: 13))
            context.addLine(to: CGPoint(x: 32, y: 51))
            context.strokePath()
        }
    }

    private static let ring = paint { context in
        context.setStrokeColor(red: 1, green: 0.38, blue: 0.18, alpha: 0.94)
        context.setLineWidth(3.0)
        context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 58, height: 58))
        context.setStrokeColor(gray: 1, alpha: 0.85)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: 7, y: 7, width: 50, height: 50))
    }
}
