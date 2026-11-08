import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import Vision

enum PortraitStyle: String, CaseIterable, Identifiable, Sendable {
    case camera = "真人画面"
    case puppy = "黄色小狗面具"
    case swirl = "便便面具"
    case boy = "男生面具"
    case girl = "女生面具"

    var id: Self { self }
    var isFaceMask: Bool { self != .camera }
}

enum FaceMaskState: Equatable, Sendable {
    case waiting, tracking, multipleFaces

    var message: String {
        switch self {
        case .waiting: "人像已遮住 · 请正对摄像头"
        case .tracking: "面具跟随中 · 保留身体和背景"
        case .multipleFaces: "人像已遮住 · 请让画面只留一人"
        }
    }
}

struct FaceMaskPose {
    var roll: CGFloat = 0
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var leftEye: CGFloat = 1
    var rightEye: CGFloat = 1
    var mouth: CGFloat = 0
    var smile: CGFloat = 0

    mutating func follow(_ next: Self) {
        roll += (next.roll - roll) * 0.75
        yaw += (next.yaw - yaw) * 0.7
        pitch += (next.pitch - pitch) * 0.7
        leftEye += (next.leftEye - leftEye) * 0.9
        rightEye += (next.rightEye - rightEye) * 0.9
        mouth += (next.mouth - mouth) * 0.85
        smile += (next.smile - smile) * 0.7
    }
}

struct MaskedFace {
    let box: CGRect
    let pose: FaceMaskPose
}

// Retained buffers are read-only after they are handed off between queues.
private struct MaskVideoFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Face detection and drawing operate on the same frame. Only processed buffers leave mask mode.
final class FaceMaskPortrait: @unchecked Sendable {
    private let style: PortraitStyle
    private let queue = DispatchQueue(label: "local.takerec.face-mask", qos: .userInitiated)
    private let resultQueue: DispatchQueue
    private let onState: @Sendable (FaceMaskState) -> Void
    private let receive: @Sendable (CVPixelBuffer) -> Void
    private let gate = NSLock()
    private var busy = false
    private var previousFrame: ContinuousClock.Instant?
    private let landmarks = VNDetectFaceLandmarksRequest()
    private let renderer = FaceMaskRenderer()
    private var pose: FaceMaskPose?
    private var lastState: FaceMaskState?

    init(style: PortraitStyle, resultQueue: DispatchQueue, onState: @escaping @Sendable (FaceMaskState) -> Void = { _ in },
         receive: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.style = style
        self.resultQueue = resultQueue
        self.onState = onState
        self.receive = receive
    }

    func submit(_ input: CVPixelBuffer) {
        let frame = MaskVideoFrame(buffer: input)
        guard style.isFaceMask else {
            resultQueue.async { self.receive(frame.buffer) }
            return
        }
        let now = ContinuousClock.now
        gate.lock()
        if busy || previousFrame.map({ $0.duration(to: now) < .milliseconds(28) }) == true {
            gate.unlock()
            return
        }
        busy = true
        previousFrame = now
        gate.unlock()

        queue.async {
            autoreleasepool {
                let (face, state) = self.detect(in: frame.buffer)
                guard let rendered = self.renderer.frame(frame.buffer, style: self.style, face: face) else {
                    self.releaseFrame()
                    return
                }
                if self.lastState != state {
                    self.lastState = state
                    self.onState(state)
                }
                let output = MaskVideoFrame(buffer: rendered)
                self.resultQueue.async {
                    self.receive(output.buffer)
                    self.releaseFrame()
                }
            }
        }
    }

    private func releaseFrame() {
        gate.lock()
        busy = false
        gate.unlock()
    }

    private func detect(in buffer: CVPixelBuffer) -> (MaskedFace?, FaceMaskState) {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([landmarks])) != nil, let faces = landmarks.results, !faces.isEmpty else {
            pose = nil
            return (nil, .waiting)
        }
        guard faces.count == 1, let face = faces.first else {
            pose = nil
            return (nil, .multipleFaces)
        }
        let box = face.boundingBox
        let width = box.width * CGFloat(CVPixelBufferGetWidth(buffer))
        let height = box.height * CGFloat(CVPixelBufferGetHeight(buffer))
        let yaw = face.yaw?.doubleValue ?? 0
        let pitch = face.pitch?.doubleValue ?? 0
        guard face.confidence >= 0.60, width >= 26, height >= 26, abs(yaw) <= 0.9, abs(pitch) <= 0.9,
              let points = face.landmarks, points.faceContour != nil, points.nose != nil,
              points.leftEye != nil, points.rightEye != nil, points.outerLips != nil else {
            pose = nil
            return (nil, .waiting)
        }
        let ratio = height / width
        func openness(_ region: VNFaceLandmarkRegion2D?, baseline: CGFloat, span: CGFloat, fallback: CGFloat) -> CGFloat {
            guard let points = region?.normalizedPoints, points.count >= 3,
                  let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX - minX > 0.002 else { return fallback }
            return clamp(((maxY - minY) * ratio / (maxX - minX) - baseline) / span, 0, 1)
        }
        let mouthWidth = (points.outerLips?.normalizedPoints.map(\.x).max() ?? 0) -
            (points.outerLips?.normalizedPoints.map(\.x).min() ?? 0)
        let next = FaceMaskPose(roll: clamp(-CGFloat(face.roll?.doubleValue ?? 0), -0.75, 0.75),
                                yaw: clamp(yaw, -0.9, 0.9), pitch: clamp(pitch, -0.9, 0.9),
                                leftEye: openness(points.leftEye, baseline: 0.11, span: 0.17, fallback: 1),
                                rightEye: openness(points.rightEye, baseline: 0.11, span: 0.17, fallback: 1),
                                mouth: openness(points.innerLips, baseline: 0.06, span: 0.39, fallback: 0),
                                smile: clamp((mouthWidth - 0.30) / 0.25, 0, 1))
        var stable = pose ?? next
        stable.follow(next)
        pose = stable
        return (MaskedFace(box: box, pose: stable), .tracking)
    }
}

/// A single worker owns the pool. Source bytes are copied only when the face can be covered.
final class FaceMaskRenderer {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    private var protectedFrame: CVPixelBuffer?
    private let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func frame(_ source: CVPixelBuffer, style: PortraitStyle, face: MaskedFace?) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        if pool == nil || width != w || height != h {
            width = w
            height = h
            pool = nil
            protectedFrame = nil
            let attributes = [
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary
            guard CVPixelBufferPoolCreate(nil, nil, attributes, &pool) == kCVReturnSuccess else { return nil }
        }
        if face == nil, let protectedFrame { return protectedFrame }
        guard let pool else { return nil }
        var next: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &next) == kCVReturnSuccess, let next,
              CVPixelBufferLockBaseAddress(next, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(next, []) }

        let stride = CVPixelBufferGetBytesPerRow(next)
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let bytes = CVPixelBufferGetBaseAddress(next),
              let canvas = CGContext(data: bytes, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: stride, space: space, bitmapInfo: bitmap) else { return nil }

        if let face {
            guard Self.copy(source, to: bytes, stride: stride, width: w, height: h) else { return nil }
            CVBufferPropagateAttachments(source, next)
            canvas.translateBy(x: 0, y: CGFloat(h))
            canvas.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: face.box.minX * CGFloat(w), y: (1 - face.box.maxY) * CGFloat(h),
                              width: face.box.width * CGFloat(w), height: face.box.height * CGFloat(h))
            Self.drawMask(canvas, style: style, face: rect, pose: face.pose)
        } else {
            canvas.setFillColor(Self.color(0x272335))
            canvas.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let side = CGFloat(min(w, h)) * 0.095
            let symbol = CGRect(x: (CGFloat(w) - side) / 2, y: (CGFloat(h) - side) / 2, width: side, height: side)
            canvas.setLineWidth(max(2, side * 0.06))
            canvas.setStrokeColor(Self.color(0xD1C9E5))
            canvas.strokeEllipse(in: symbol)
            canvas.move(to: CGPoint(x: symbol.minX + side * 0.16, y: symbol.minY + side * 0.16))
            canvas.addLine(to: CGPoint(x: symbol.maxX - side * 0.16, y: symbol.maxY - side * 0.16))
            canvas.strokePath()
        }
        canvas.flush()
        if face == nil { protectedFrame = next }
        return next
    }

    private static func copy(_ source: CVPixelBuffer, to bytes: UnsafeMutableRawPointer,
                             stride: Int, width: Int, height: Int) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(source) else { return false }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        for row in 0..<height {
            memcpy(bytes + row * stride, base + row * sourceStride, width * 4)
        }
        return true
    }

    private static func drawMask(_ canvas: CGContext, style: PortraitStyle, face: CGRect, pose: FaceMaskPose) {
        let center = CGPoint(x: face.midX, y: face.midY - face.height * 0.055)
        let coverage = face.insetBy(dx: -face.width * 0.11, dy: -face.height * 0.11)
        // Fit the coverage in the mask's rotated coordinates so head tilt cannot uncover box corners.
        let rotated = coverage.offsetBy(dx: -center.x, dy: -center.y)
            .applying(CGAffineTransform(rotationAngle: -pose.roll))
        let cornerCoverage = CGFloat(2).squareRoot()
        let halfWidth = max(abs(rotated.minX), abs(rotated.maxX)) * cornerCoverage
        let halfHeight = max(abs(rotated.minY), abs(rotated.maxY)) * cornerCoverage
        let backing = CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        let base: UInt32
        switch style {
        case .camera: base = 0xE7E2E9
        case .puppy: base = 0xFAD379
        case .swirl: base = 0xF4CFB2
        case .boy, .girl: base = 0xEAB18C
        }
        canvas.translateBy(x: center.x, y: center.y)
        canvas.rotate(by: pose.roll)
        canvas.setFillColor(color(base))
        canvas.fillEllipse(in: backing)
        // Draw the animated character head inside the opaque covering, with no image asset.
        canvas.scaleBy(x: backing.width / 350, y: backing.height / 330)
        canvas.translateBy(x: -240, y: -218)
        switch style {
        case .camera: break
        case .puppy: puppy(canvas, pose)
        case .swirl: swirl(canvas, pose)
        case .boy, .girl: human(canvas, pose, longHair: style == .girl)
        }
    }

    private static func puppy(_ c: CGContext, _ pose: FaceMaskPose) {
        oval(c, 88, 113, 94, 178, 0xA45E35)
        oval(c, 298, 113, 94, 178, 0xA45E35)
        oval(c, 114, 91, 252, 243, 0xF7BE46)
        oval(c, 168, 233, 144, 88, 0xFFE6A1)
        oval(c, 199 + pose.yaw * 10, 233, 82, 21, 0x533627)
        oval(c, 154, 239, 30, 14, 0xEF8F70)
        oval(c, 296, 239, 30, 14, 0xEF8F70)
        features(c, pose, eyeY: 203, mouthY: 272, ink: 0x443126)
    }

    private static func swirl(_ c: CGContext, _ pose: FaceMaskPose) {
        shape(c, 0x935430) { p in
            p.move(to: CGPoint(x: 116, y: 342))
            p.addQuadCurve(to: CGPoint(x: 141, y: 267), control: CGPoint(x: 91, y: 295))
            p.addQuadCurve(to: CGPoint(x: 161, y: 208), control: CGPoint(x: 120, y: 235))
            p.addQuadCurve(to: CGPoint(x: 205, y: 143), control: CGPoint(x: 139, y: 166))
            p.addQuadCurve(to: CGPoint(x: 253, y: 77), control: CGPoint(x: 258, y: 119))
            p.addQuadCurve(to: CGPoint(x: 293, y: 165), control: CGPoint(x: 311, y: 112))
            p.addQuadCurve(to: CGPoint(x: 324, y: 219), control: CGPoint(x: 345, y: 181))
            p.addQuadCurve(to: CGPoint(x: 350, y: 272), control: CGPoint(x: 374, y: 240))
            p.addQuadCurve(to: CGPoint(x: 360, y: 340), control: CGPoint(x: 399, y: 303))
            p.addQuadCurve(to: CGPoint(x: 116, y: 342), control: CGPoint(x: 246, y: 391))
        }
        oval(c, 140, 262, 202, 70, 0xBB7B50)
        oval(c, 160, 199, 168, 96, 0xB06B45)
        oval(c, 174, 267, 30, 15, 0xE99583)
        oval(c, 276, 267, 30, 15, 0xE99583)
        features(c, pose, eyeY: 230, mouthY: 287, ink: 0x452923)
    }

    private static func human(_ c: CGContext, _ pose: FaceMaskPose, longHair: Bool) {
        let hair: UInt32 = longHair ? 0x60344C : 0x2D3F56
        if longHair { oval(c, 119, 81, 242, 271, hair) }
        oval(c, 130, 188, 51, 67, 0xE5A57D)
        oval(c, 299, 188, 51, 67, 0xE5A57D)
        oval(c, 147, 96, 186, 221, 0xFFC49B)
        shape(c, hair) { p in
            p.move(to: CGPoint(x: 144, y: 195))
            p.addQuadCurve(to: CGPoint(x: 175, y: 99), control: CGPoint(x: 127, y: 138))
            p.addQuadCurve(to: CGPoint(x: 298, y: 90), control: CGPoint(x: 228, y: 62))
            p.addQuadCurve(to: CGPoint(x: 338, y: 196), control: CGPoint(x: 350, y: 122))
            p.addQuadCurve(to: CGPoint(x: 273, y: 134), control: CGPoint(x: 307, y: 170))
            p.addQuadCurve(to: CGPoint(x: 144, y: 195), control: CGPoint(x: 221, y: 184))
        }
        if longHair { oval(c, 129, 235, 17, 17, 0xFFE19B); oval(c, 334, 235, 17, 17, 0xFFE19B) }
        oval(c, 162, 236, 35, 15, 0xF5A48C)
        oval(c, 283, 236, 35, 15, 0xF5A48C)
        oval(c, 232 + pose.yaw * 11, 231, 16, 10, 0xE79C79)
        features(c, pose, eyeY: 207, mouthY: 260, ink: 0x4F3438, spacing: 44)
    }

    private static func features(_ c: CGContext, _ pose: FaceMaskPose, eyeY: CGFloat, mouthY: CGFloat,
                                 ink: UInt32, spacing: CGFloat = 53) {
        let center = 240 + pose.yaw * 25
        let eyeDistance = spacing * (1 - abs(pose.yaw) * 0.18)
        let vertical = pose.pitch * 17
        eye(c, x: center - eyeDistance, y: eyeY + vertical, openness: pose.leftEye, yaw: pose.yaw, ink: ink)
        eye(c, x: center + eyeDistance, y: eyeY + vertical, openness: pose.rightEye, yaw: pose.yaw, ink: ink)
        let width = 34 + pose.smile * 24
        let height = 6 + pose.mouth * 45
        let mouth = mouthY + vertical - pose.smile * 5
        if pose.mouth < 0.12 {
            let line = CGMutablePath()
            line.move(to: CGPoint(x: center - width / 2, y: mouth))
            line.addQuadCurve(to: CGPoint(x: center + width / 2, y: mouth),
                              control: CGPoint(x: center, y: mouth + 5 + pose.smile * 16))
            c.addPath(line)
            c.setStrokeColor(color(ink))
            c.setLineWidth(6)
            c.setLineCap(.round)
            c.strokePath()
        } else {
            oval(c, center - width / 2, mouth, width, height, ink)
            if pose.mouth > 0.28 {
                oval(c, center - width * 0.28, mouth + height * 0.58, width * 0.56, height * 0.32, 0xED8C8A)
            }
        }
    }

    private static func eye(_ c: CGContext, x: CGFloat, y: CGFloat, openness: CGFloat, yaw: CGFloat, ink: UInt32) {
        let height = max(4, 35 * openness)
        if openness < 0.23 {
            oval(c, x - 17, y - height / 2, 34, height, ink)
            return
        }
        oval(c, x - 19, y - height / 2, 38, height, 0xFFF8EC)
        let irisX = x - 10 + yaw * 9
        oval(c, irisX, y - height * 0.38, 20, height * 0.76, ink)
        oval(c, irisX + 3, y - height * 0.23, 6, max(3, height * 0.2), 0xFFFFFF)
    }

    private static func oval(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ value: UInt32) {
        c.setFillColor(color(value))
        c.fillEllipse(in: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func shape(_ c: CGContext, _ value: UInt32, _ draw: (CGMutablePath) -> Void) {
        let path = CGMutablePath()
        draw(path)
        path.closeSubpath()
        c.addPath(path)
        c.setFillColor(color(value))
        c.fillPath()
    }

    private static func color(_ value: UInt32) -> CGColor {
        CGColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
