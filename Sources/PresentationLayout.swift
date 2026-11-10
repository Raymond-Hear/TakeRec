import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

enum OutputFraming: String, CaseIterable, Codable, Identifiable, Sendable {
    case source, widescreen, portrait

    var id: Self { self }
    var title: String {
        switch self {
        case .source: "原比例"
        case .widescreen: "16:9 横屏"
        case .portrait: "9:16 竖屏"
        }
    }
}

struct CanvasPlacement: Codable, Equatable, Sendable {
    var width: Double
    var x: Double
    var y: Double

    func bounds(in canvas: CGRect, aspect: CGFloat) -> CGRect {
        let ratio = max(0.01, aspect)
        let width = min(canvas.width * clamp(self.width, 0.06, 1), canvas.height * ratio)
        let height = width / ratio
        let x = clamp(canvas.width * self.x, width / 2, canvas.width - width / 2)
        let y = clamp(canvas.height * (1 - self.y), height / 2, canvas.height - height / 2)
        return CGRect(x: canvas.minX + x - width / 2, y: canvas.minY + y - height / 2, width: width, height: height)
    }
}

enum CanvasBackground: String, CaseIterable, Codable, Identifiable, Sendable {
    case lavender, ocean, paper, image

    var id: Self { self }
    var title: String {
        switch self {
        case .lavender: "暮色紫"
        case .ocean: "深海蓝"
        case .paper: "暖砂白"
        case .image: "导入的图片"
        }
    }

    func render(in bounds: CGRect, imported: CIImage?) -> CIImage {
        if self == .image, let imported, imported.extent.width > 0, imported.extent.height > 0 {
            let scale = max(bounds.width / imported.extent.width, bounds.height / imported.extent.height)
            let scaled = imported.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: bounds.midX - scaled.extent.midX,
                                                            y: bounds.midY - scaled.extent.midY)).cropped(to: bounds)
        }
        let colors: (CIColor, CIColor)
        switch self {
        case .lavender, .image:
            colors = (CIColor(red: 0.16, green: 0.12, blue: 0.29), CIColor(red: 0.50, green: 0.38, blue: 0.67))
        case .ocean:
            colors = (CIColor(red: 0.025, green: 0.12, blue: 0.21), CIColor(red: 0.15, green: 0.45, blue: 0.57))
        case .paper:
            colors = (CIColor(red: 0.80, green: 0.71, blue: 0.63), CIColor(red: 0.99, green: 0.96, blue: 0.89))
        }
        let filter = CIFilter.linearGradient()
        filter.point0 = bounds.origin
        filter.point1 = CGPoint(x: bounds.maxX, y: bounds.maxY)
        filter.color0 = colors.0
        filter.color1 = colors.1
        return (filter.outputImage ?? CIImage(color: colors.0)).cropped(to: bounds)
    }

    static func importedImage(at url: URL) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else {
            throw RecorderError.message("无法读取这张背景图片。")
        }
        return picture
    }
}

struct PortraitCanvas: Codable, Equatable, Sendable {
    var pixelWidth = 1080
    var screen = CanvasPlacement(width: 0.92, x: 0.5, y: 0.34)
    var camera = CanvasPlacement(width: 0.34, x: 0.5, y: 0.81)
    var cameraShape = CameraShape.circle
    var background = CanvasBackground.lavender
    var backgroundAsset: String?
    var showsProgress = true

    var units: Int { min(120, max(30, Int((Double(pixelWidth) / 18).rounded()))) }
    var dimensions: CGSize { CGSize(width: units * 18, height: units * 32) }
    var cameraAspect: CGFloat { cameraShape == .circle ? 1 : 4.0 / 3 }
}

struct PresentationSettings: Codable, Equatable, Sendable {
    var framing = OutputFraming.source
    var portrait = PortraitCanvas()

    func screenBounds(in canvas: CGRect, sourceAspect: CGFloat) -> CGRect {
        switch framing {
        case .source:
            return canvas
        case .widescreen:
            return CanvasPlacement(width: 1, x: 0.5, y: 0.5).bounds(in: canvas, aspect: sourceAspect)
        case .portrait:
            return portrait.screen.bounds(in: canvas, aspect: sourceAspect)
        }
    }

    func cameraBoxes(in canvas: CGRect, count: Int, settings: EffectSettings) -> [CGRect] {
        guard count > 0 else { return [] }
        let edge = min(canvas.width, canvas.height)
        let margin = edge * 0.032
        let gap = edge * 0.015
        let side = edge * clamp(settings.cameraSize, 0.12, 0.55)
        let right = settings.cameraCorner == .topRight || settings.cameraCorner == .bottomRight
        let top = settings.cameraCorner == .topRight || settings.cameraCorner == .topLeft
        let portraitMode = framing == .portrait
        let base = portraitMode ? portrait.camera.bounds(in: canvas, aspect: portrait.cameraAspect) :
            CGRect(x: right ? canvas.maxX - margin - side : canvas.minX + margin,
                   y: top ? canvas.maxY - margin - side : canvas.minY + margin, width: side, height: side)
        if count == 1 { return [base] }

        let gaps = gap * CGFloat(count - 1)
        let width = min(base.width, (canvas.width - margin * 2 - gaps) / CGFloat(count))
        let height = width * base.height / base.width
        let groupWidth = width * CGFloat(count) + gaps
        let left = portraitMode
            ? clamp(base.midX - groupWidth / 2, canvas.minX + margin, canvas.maxX - margin - groupWidth)
            : (right ? base.maxX - groupWidth : base.minX)
        let bottom = portraitMode ? base.midY - height / 2 : (top ? base.maxY - height : base.minY)
        return (0..<count).map { index in
            CGRect(x: left + (width + gap) * CGFloat(index), y: bottom, width: width, height: height)
        }
    }

    func renderSize(source: CGSize, scale: CGFloat, resolution: VideoResolution, proxy: Bool) throws -> CGSize {
        switch framing {
        case .source:
            return proxy ? try CaptureSize(points: source, scale: scale, limit: 854, shortSideLimit: 480).dimensions
                : try resolution.size(for: source, scale: scale).dimensions
        case .widescreen:
            let limit = proxy ? 26 : (resolution == .hd ? 60 : 120)
            let native = ceil(max(source.width / 32, source.height / 18) * scale)
            let units = Int(clamp(native, 1, Double(limit)))
            return CGSize(width: units * 32, height: units * 18)
        case .portrait:
            let units = min(portrait.units, proxy ? 15 : (resolution == .hd ? 60 : 120))
            return CGSize(width: units * 18, height: units * 32)
        }
    }
}
