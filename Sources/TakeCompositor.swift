@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct VideoSpan: Sendable {
    let clip: TimelineClip
    let transform: CGAffineTransform
    var motion: MotionEffects?
    var drawsCursor = false
    var keyboard: KeyboardTrace?
}

struct CameraVideoLane: Sendable {
    let id: CMPersistentTrackID
    let spans: [VideoSpan]
    let mirrored: Bool
}

final class TakeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let screenID: CMPersistentTrackID?
    let screens: [VideoSpan]
    let cameras: [CameraVideoLane]
    let settings: EffectSettings
    let presentation: PresentationSettings
    let sourceAspect: CGFloat
    let background: CIImage?
    let captions: SubtitleArtwork
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let enablePostProcessing = true
    let containsTweening = true

    var requiredSourceTrackIDs: [NSValue]? {
        let visible = [screens.isEmpty ? nil : screenID].compactMap { $0 } + cameras.filter { !$0.spans.isEmpty }.map(\.id)
        let required = visible.isEmpty ? [screenID ?? cameras.first?.id].compactMap { $0 } : visible
        return required.map { NSNumber(value: $0) }
    }

    init(timeRange: CMTimeRange, screenID: CMPersistentTrackID?,
         screens: [VideoSpan], cameras: [CameraVideoLane], settings: EffectSettings,
         presentation: PresentationSettings, sourceAspect: CGFloat, background: CIImage?, captions: SubtitleArtwork) {
        self.timeRange = timeRange
        self.screenID = screenID
        self.screens = screens
        self.cameras = cameras
        self.settings = settings
        self.presentation = presentation
        self.sourceAspect = sourceAspect
        self.background = background
        self.captions = captions
    }

    func screen(at time: Double) -> VideoSpan? { span(in: screens, at: time) }
    func camera(in lane: CameraVideoLane, at time: Double) -> VideoSpan? { span(in: lane.spans, at: time) }

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
    private let keyboardArtwork = KeyboardArtwork()

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
        let settings = instruction.settings
        let layout = instruction.presentation
        let portrait = layout.framing == .portrait ? layout.portrait : nil
        let black = CIImage(color: .black).cropped(to: canvas)
        var result = portrait?.background.render(in: canvas, imported: instruction.background).composited(over: black) ?? black
        if let screen, let id = instruction.screenID, let source = request.sourceFrame(byTrackID: id) {
            let box = layout.screenBounds(in: canvas, sourceAspect: instruction.sourceAspect)
            let local = CGRect(origin: .zero, size: box.size)
            let layer = screenLayer(oriented(source, transform: screen.transform), span: screen, time: time,
                                    canvas: local, settings: settings)
            result = layer.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY)).composited(over: result)
        }
        let cameraImages = instruction.cameras.compactMap { lane -> (CIImage, Bool)? in
            guard let span = instruction.camera(in: lane, at: time), let buffer = request.sourceFrame(byTrackID: lane.id) else { return nil }
            return (oriented(buffer, transform: span.transform), lane.mirrored)
        }
        let boxes = layout.cameraBoxes(in: canvas, count: cameraImages.count, settings: settings)
        for ((image, mirrored), box) in zip(cameraImages, boxes) {
            result = cameraOverlay(image, on: result, box: box, mirrored: mirrored,
                                   shape: portrait?.cameraShape ?? settings.cameraShape, lighting: settings.portraitLighting)
        }
        if portrait?.showsProgress == true {
            result = progress(at: time, duration: instruction.timeRange.duration.seconds, in: canvas).composited(over: result)
        }
        if settings.showKeyboard != false, let clip = screen?.clip, let keys = screen?.keyboard,
           let overlay = keyboardArtwork.overlay(
               labels: keys.recentLabels(at: clip.sourceStart + time - clip.at, since: clip.sourceStart),
               corner: settings.keyboardCorner ?? keys.corner, canvas: canvas) {
            result = overlay.composited(over: result)
        }
        if let overlay = instruction.captions.overlay(at: time, in: canvas, portrait: portrait != nil) {
            result = overlay.composited(over: result)
        }
        context.render(result.cropped(to: canvas), to: output, bounds: canvas, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    private func screenLayer(_ image: CIImage, span: VideoSpan, time: Double,
                             canvas: CGRect, settings: EffectSettings) -> CIImage {
        let effect = span.motion?.frame(at: time) ?? MotionEffects.Frame()
        let pan = effect.pan(in: canvas)
        let black = CIImage(color: .black).cropped(to: canvas)
        var result = fit(image, in: canvas, fill: false).composited(over: black).transformed(by: pan).cropped(to: canvas)
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
        if span.drawsCursor, settings.cursor != .hidden {
            for (index, point) in effect.trail.enumerated() {
                let position = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height).applying(pan)
                let dot = Self.dot.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.17 + 0.10 * Double(index))
                ])
                result = sprite(dot, at: position, hotspot: CGPoint(x: 32, y: 32), side: cursorUnit * 0.64)
                    .composited(over: result)
            }
        }
        if span.drawsCursor, let point = effect.cursor, let glyph = Self.glyph(settings.cursor) {
            let hotspot = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height).applying(pan)
            result = sprite(glyph.0, at: hotspot, hotspot: glyph.1,
                            side: cursorUnit * clamp(settings.cursorSize, 0.5, 3)).composited(over: result)
        }
        return result.cropped(to: canvas)
    }

    private func progress(at time: Double, duration: Double, in canvas: CGRect) -> CIImage {
        let bar = CGRect(x: canvas.width * 0.16, y: canvas.height * 0.44,
                         width: canvas.width * 0.68, height: max(2, canvas.width * 0.004))
        let rail = rounded(bar, radius: bar.height / 2, color: CIColor(red: 0.12, green: 0.09, blue: 0.23, alpha: 0.26))
        let width = bar.width * clamp(time / duration, 0, 1)
        guard width > 0 else { return rail }
        let fill = CGRect(origin: bar.origin, size: CGSize(width: width, height: bar.height))
        return rounded(fill, radius: min(width, bar.height) / 2,
                       color: CIColor(red: 0.81, green: 0.73, blue: 1)).composited(over: rail)
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

    private func cameraOverlay(_ camera: CIImage, on background: CIImage, box: CGRect,
                               mirrored: Bool, shape: CameraShape, lighting: PortraitLighting?) -> CIImage {
        let mask = rounded(box, radius: min(box.width, box.height) * (shape == .circle ? 0.5 : 0.18), color: .white)
        let adjusted = lighting?.apply(to: camera) ?? camera
        let fitted = fit(adjusted, in: box, fill: true)
        let subject = mirrored
            ? fitted.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: box.midX * 2, ty: 0))
            : fitted
        return subject.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask
        ])
    }

    private func rounded(_ box: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = box
        shape.radius = Float(radius)
        shape.color = color
        return shape.outputImage ?? CIImage(color: color).cropped(to: box)
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
