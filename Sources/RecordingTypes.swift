import AVFoundation
import Foundation

func isPhoneInput(_ id: String?) -> Bool {
    #if TAKEREC_STORE
    return false
    #else
    return id == PhoneLink.deviceID
    #endif
}

enum CursorAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "真实系统光标"
    case editable = "可编辑样式"
    var id: Self { self }
}

enum VideoResolution: String, CaseIterable, Identifiable, Sendable {
    case hd = "1080p"
    case uhd = "4K"

    var id: Self { self }

    func size(for points: CGSize, scale: CGFloat = 1) throws -> CaptureSize {
        try CaptureSize(points: points, scale: scale, limit: self == .hd ? 1920 : 3840,
                        shortSideLimit: self == .hd ? 1080 : 2160)
    }
}

struct CaptureOptions: Sendable {
    var cameraID: String?
    var microphone = false
    var systemAudio = false
    var cursorAppearance = CursorAppearance.system
    var recordClickEffects = true
    var microphoneID: String?
    var personShape = CameraShape.circle
    var mirrorCamera = false
    var prioritizeNarration = true
    var portraitStyle = PortraitStyle.camera
    var screenResolution = VideoResolution.uhd
    var cameraResolution = VideoResolution.hd
    var portraitLighting: PortraitLighting?
    var microphoneGain = 1.0
    var keyboard: KeyboardCaptureOptions?
    var additionalCameras: [TrackKind: String] = [:]
    var cameraNames: [TrackKind: String] = [:]

    var cameras: [TrackKind: String] {
        var selected = additionalCameras.filter { $0.key.isCamera && $0.key != .camera }
        selected[.camera] = cameraID
        return selected
    }

    func resolution(for camera: TrackKind) -> VideoResolution {
        camera == .camera ? cameraResolution : .hd
    }
}

enum PreviewGeometry {
    static func fit(_ source: CGSize, in available: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0,
              available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / source.width, available.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

enum TrackKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case screen, camera, camera2, camera3, system, microphone, originalAudio

    static let cameraTracks: [Self] = [.camera, .camera2, .camera3]
    var id: Self { self }
    var isCamera: Bool { Self.cameraTracks.contains(self) }
    var isVideo: Bool { self == .screen || isCamera }
    var angleTitle: String {
        switch self {
        case .camera: "机位 1"
        case .camera2: "机位 2"
        case .camera3: "机位 3"
        default: title
        }
    }
    var maximumVolume: Double { self == .microphone ? 2 : 1 }
    var isBackgroundAudio: Bool { self == .system || self == .originalAudio }
    var filename: String {
        switch self {
        case .screen, .originalAudio: "screen.mp4"
        case .camera: "camera.mp4"
        case .camera2: "camera-2.mp4"
        case .camera3: "camera-3.mp4"
        case .system: "system.m4a"
        case .microphone: "microphone.m4a"
        }
    }
    var title: String {
        switch self {
        case .screen: "屏幕"
        case .camera: "人像"
        case .camera2: "机位 2"
        case .camera3: "机位 3"
        case .system: "系统声音"
        case .microphone: "麦克风"
        case .originalAudio: "原片声音"
        }
    }
}

struct CaptureSize: Sendable {
    static let framesPerSecond: Int32 = 30
    let width: Int
    let height: Int

    init(points: CGSize, scale: CGFloat, limit: CGFloat = 1920,
         shortSideLimit: CGFloat = .greatestFiniteMagnitude) throws {
        let longestSide = max(points.width, points.height)
        let shortestSide = min(points.width, points.height)
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              shortestSide > 0, scale > 0 else {
            throw RecorderError.message("所选画面没有可录制的尺寸，请重新选择。")
        }
        let factor = min(scale, limit / longestSide, shortSideLimit / shortestSide)
        width = max(2, Int(points.width * factor) / 2 * 2)
        height = max(2, Int(points.height * factor) / 2 * 2)
    }

    var dimensions: CGSize { CGSize(width: width, height: height) }
    var pixelLabel: String { "\(width) × \(height)" }
}

enum RecorderError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

struct CameraSource: Identifiable {
    let id: String
    let name: String

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

struct MicrophoneSource: Identifiable {
    let id: String
    let name: String

    static func devices() -> [AVCaptureDevice] {
        let available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                        mediaType: .audio, position: .unspecified).devices
        guard let preferred = AVCaptureDevice.default(for: .audio) else { return available }
        return [preferred] + available.filter { $0.uniqueID != preferred.uniqueID }
    }
}
