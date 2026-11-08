@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation

private let screenPreviewLimit: CGFloat = 1920

private final class ScreenSamples: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.desktake.screen", qos: .userInitiated)
    private let decoder = PreviewImageDecoder(limit: screenPreviewLimit)
    private let onPreview: @Sendable (CGImage) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let onOverlay: @Sendable (Bool) -> Void
    private var recording: (writer: MovieWriter, size: CaptureSize)?
    private var delegateOverlay = false
    private var markedFrame = false
    private var isBlocked = false
    private var recordingInterrupted = false

    init(onPreview: @escaping @Sendable (CGImage) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void,
         onOverlay: @escaping @Sendable (Bool) -> Void) {
        self.onPreview = onPreview
        self.onFailure = onFailure
        self.onOverlay = onOverlay
    }

    func attach(_ recording: (writer: MovieWriter, size: CaptureSize)?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if recording != nil, self.isBlocked {
                    continuation.resume(throwing: ScreenSource.overlayError)
                    return
                }
                self.recording = recording
                self.recordingInterrupted = false
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first
            let status = (attachments?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
            if status == .blank || status == .suspended || status == .stopped {
                recording?.writer.receiveScreen(nil)
                return
            }
            guard status == nil || status == .complete || status == .started else { return }
            markedFrame = ScreenSource.hasOverlayTag(attachments?[.presenterOverlayContentRect])
            updateOverlay()
            guard !isBlocked, !recordingInterrupted, let frame = sample.imageBuffer else { return }
            if let recording {
                // The stream can still deliver queued preview frames after a configuration update.
                guard CVPixelBufferGetWidth(frame) == recording.size.width,
                      CVPixelBufferGetHeight(frame) == recording.size.height else { return }
                recording.writer.receiveScreen(frame)
            } else if let image = decoder.frame(frame) {
                onPreview(image)
            }
        case .audio:
            if !recordingInterrupted { recording?.writer.receiveAudio(sample, source: .system) }
        case .microphone:
            break
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure(error) }

    func outputVideoEffectDidStart(for stream: SCStream) {
        queue.async {
            self.delegateOverlay = true
            self.updateOverlay()
        }
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        queue.async {
            self.delegateOverlay = false
            self.markedFrame = false
            self.updateOverlay()
        }
    }

    private func updateOverlay() {
        let blocked = delegateOverlay || markedFrame
        if blocked != isBlocked {
            isBlocked = blocked
            onOverlay(blocked)
        }
        if blocked, let recording, !recordingInterrupted {
            // Drop flagged frames before they can reach the recording. Keep the clean prefix.
            recordingInterrupted = true
            recording.writer.receiveScreen(nil)
            onFailure(ScreenSource.overlayError)
        }
    }
}

enum RecordingPanelAvailability {
    case available, needsPermission, unsupported, cannotExclude

    var notice: String? {
        switch self {
        case .available: nil
        case .needsPermission: "授权后，简录才能从全屏录像里排除浮条和提词器。"
        case .unsupported: "全屏浮条需要 macOS 15.2 或更新版本。也可以用单窗口录制。"
        case .cannotExclude: "这次选择无法排除简录窗口。请重选屏幕或选择单窗口。"
        }
    }
}

@MainActor
final class ScreenSource {
    nonisolated static var overlayError: RecorderError {
        .message("系统人物前置已打开。请在 macOS 录制菜单关闭它，并在 App 里选圆形人像。")
    }

    nonisolated static func hasOverlayTag(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let rect = value as? CGRect { return !rect.isEmpty }
        if let dictionary = value as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            return !rect.isEmpty
        }
        return true
    }

    static func prepareSelection(_ selection: SCContentFilter) async -> (SCContentFilter, RecordingPanelAvailability) {
        if selection.style == .window { return (selection, .available) }
        guard selection.style == .display else { return (selection, .cannotExclude) }
        guard #available(macOS 15.2, *) else { return (selection, .unsupported) }
        guard CGPreflightScreenCaptureAccess() else { return (selection, .needsPermission) }
        guard let display = selection.includedDisplays.first else { return (selection, .cannotExclude) }
        let pid = ProcessInfo.processInfo.processIdentifier
        var recorder = (try? await SCShareableContent.currentProcess)?.applications.first { $0.processID == pid }
        if recorder == nil {
            recorder = (try? await SCShareableContent.current)?.applications.first { $0.processID == pid }
        }
        guard let recorder else { return (selection, .cannotExclude) }
        let filter = SCContentFilter(display: display, excludingApplications: [recorder], exceptingWindows: [])
        filter.includeMenuBar = selection.includeMenuBar
        return (filter, .available)
    }

    static func panelDisplayID(for selection: SCContentFilter) -> CGDirectDisplayID? {
        if #available(macOS 15.2, *) {
            if selection.style == .display, let display = selection.includedDisplays.first { return display.displayID }
            if selection.style == .window, let window = selection.includedWindows.first {
                let matches = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGFloat)? in
                    guard let id = screen.captureDisplayID else { return nil }
                    let overlap = CGDisplayBounds(id).intersection(window.frame)
                    guard !overlap.isEmpty else { return nil }
                    return (id, overlap.width * overlap.height)
                }
                if let display = matches.max(by: { $0.1 < $1.1 }) { return display.0 }
            }
        }
        return NSScreen.main?.captureDisplayID
    }

    let filter: SCContentFilter
    let panelAvailability: RecordingPanelAvailability
    let panelDisplayID: CGDirectDisplayID?
    private let stream: SCStream
    private let samples: ScreenSamples
    private(set) var running = false
    var queue: DispatchQueue { samples.queue }
    var clock: CMClock? { stream.synchronizationClock }

    init(filter: SCContentFilter, panelAvailability: RecordingPanelAvailability,
         panelDisplayID: CGDirectDisplayID?,
         onPreview: @escaping @Sendable (CGImage) -> Void = { _ in },
         onFailure: @escaping @Sendable (Error) -> Void,
         onOverlay: @escaping @Sendable (Bool) -> Void = { _ in }) throws {
        self.filter = filter
        self.panelAvailability = panelAvailability
        self.panelDisplayID = panelDisplayID
        let size = try CaptureSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale),
                                   limit: screenPreviewLimit)
        samples = ScreenSamples(onPreview: onPreview, onFailure: onFailure, onOverlay: onOverlay)
        stream = SCStream(filter: filter, configuration: Self.configuration(size: size, options: nil), delegate: samples)
        try stream.addStreamOutput(samples, type: .screen, sampleHandlerQueue: samples.queue)
    }

    func size(for resolution: VideoResolution) throws -> CaptureSize {
        try resolution.size(for: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
    }

    func pixelSize() throws -> CaptureSize {
        try CaptureSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale),
                        limit: .greatestFiniteMagnitude)
    }

    func startPreview() async throws {
        try await stream.startCapture()
        running = true
    }

    func startRecording(_ writer: MovieWriter, size: CaptureSize, options: CaptureOptions) async throws {
        if options.systemAudio { try stream.addStreamOutput(samples, type: .audio, sampleHandlerQueue: samples.queue) }
        let config = Self.configuration(size: size, options: options)
        try await stream.updateConfiguration(config)
        try await samples.attach((writer, size))
        if !running {
            try await stream.startCapture()
            running = true
        }
    }

    func stop() async {
        if running {
            running = false
            try? await stream.stopCapture()
        }
        try? await samples.attach(nil)
    }

    private static func configuration(size: CaptureSize, options: CaptureOptions?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: options == nil ? 15 : CaptureSize.framesPerSecond)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.captureResolution = .best
        config.showsCursor = options?.cursorAppearance != .editable
        config.capturesAudio = options?.systemAudio ?? false
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }
}

@MainActor
final class ScreenTake {
    private let options: CaptureOptions
    private let size: CaptureSize
    private let writer: MovieWriter
    private let source: ScreenSource
    private let camera: DeviceInput?
    private let microphone: DeviceInput?
    private let portrait: FaceMaskPortrait?
    private let phone: PhoneLink?
    private let folder: URL
    private let pointer: PointerCapture?
    private let onStarted: @MainActor (Double) -> Void
    private let onInterruption: @Sendable (Error) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let onCameraStopped: @MainActor () -> Void
    private var acceptsPointer = false

    init(source: ScreenSource, options: CaptureOptions, phone: PhoneLink, onStarted: @escaping @MainActor (Double) -> Void,
         onInterruption: @escaping @Sendable (Error) -> Void, onLevel: @escaping @Sendable (Double) -> Void,
         onCameraStopped: @escaping @MainActor () -> Void, onMaskState: @escaping @Sendable (FaceMaskState) -> Void,
         coversLocation: @escaping (CGPoint) -> Bool) throws {
        self.options = options
        self.source = source
        size = try source.size(for: options.screenResolution)
        self.onStarted = onStarted
        self.onInterruption = onInterruption
        self.onLevel = onLevel
        self.onCameraStopped = onCameraStopped
        self.phone = options.cameraID == PhoneLink.deviceID || options.microphoneID == PhoneLink.deviceID ? phone : nil
        folder = try TakeProject.temporaryFolder()
        do {
            let writer = try MovieWriter(folder: folder, size: size, options: options, queue: source.queue)
            self.writer = writer
            pointer = options.recordClickEffects || options.cursorAppearance == .editable
                ? PointerCapture(filter: source.filter, size: size, recordsClicks: options.recordClickEffects,
                                 coversLocation: coversLocation)
                : nil
            let portrait = options.cameraID.map { _ in
                FaceMaskPortrait(style: options.portraitStyle, resultQueue: writer.queue,
                                 onState: onMaskState) { writer.receiveCamera($0) }
            }
            self.portrait = portrait
            camera = options.cameraID.flatMap { id in
                guard id != PhoneLink.deviceID, let portrait else { return nil }
                return DeviceInput(media: .video, outputQueue: writer.queue,
                                   videoResolution: options.cameraResolution,
                                   video: { portrait.submit($0) })
            }
            microphone = options.microphone && options.microphoneID != PhoneLink.deviceID
                ? DeviceInput(media: .audio, outputQueue: writer.queue, audio: { sample, clock in
                writer.receiveAudio(sample, source: .microphone, inputClock: clock)
            }) : nil
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func start() async throws {
        do {
            try attachPhone()
            if let camera, let id = options.cameraID { try await camera.select(id) }
            if let microphone, let id = options.microphoneID { try await microphone.select(id) }
            try await source.startRecording(writer, size: size, options: options)
            acceptsPointer = true
            writer.begin(clock: source.clock, onStarted: { [weak self] hostTime in
                Task { @MainActor in
                    guard let self, self.acceptsPointer else { return }
                    self.pointer?.start(at: hostTime)
                    self.onStarted(hostTime)
                }
            }, onFailure: onInterruption, onLevel: onLevel, onCameraStopped: { [weak self] in
                Task { @MainActor in
                    guard let self, self.acceptsPointer else { return }
                    self.onCameraStopped()
                    try? await self.camera?.select(nil)
                }
            })
        } catch {
            phone?.setOutputs(video: nil, audio: nil)
            await source.stop()
            try? await camera?.select(nil)
            try? await microphone?.select(nil)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func attachPhone() throws {
        guard let phone else { return }
        var video: ((CVPixelBuffer) -> Void)?
        var audio: ((CMSampleBuffer) -> Void)?
        if options.cameraID == PhoneLink.deviceID {
            guard phone.hasVideo, let portrait else { throw RecorderError.message("请重新连接手机网页的摄像头。") }
            video = { portrait.submit($0) }
        }
        if options.microphoneID == PhoneLink.deviceID {
            guard phone.hasAudio else { throw RecorderError.message("请重新连接手机网页的麦克风。") }
            audio = { [writer] sample in
                let packet = PhoneAudioPacket(sample: sample)
                writer.queue.async { writer.receiveAudio(packet.sample, source: .microphone, inputClock: CMClockGetHostTimeClock()) }
            }
        }
        phone.setOutputs(video: video, audio: audio)
    }

    func setPaused(_ paused: Bool, at hostTime: CMTime) {
        writer.setPaused(paused, at: hostTime)
        pointer?.setPaused(paused, at: hostTime)
    }

    func stop() async throws -> RecordedMedia {
        acceptsPointer = false
        phone?.setOutputs(video: nil, audio: nil)
        let trace = pointer?.stop() ?? PointerTrace()
        async let draft = writer.finish()
        await source.stop()
        try? await camera?.select(nil)
        try? await microphone?.select(nil)
        do {
            var media = try await draft
            media.pointer = trace
            media.personShape = options.personShape
            media.mirrorCamera = options.mirrorCamera
            media.cursorAppearance = options.cursorAppearance
            media.prioritizeNarration = options.prioritizeNarration
            media.portraitLighting = options.portraitLighting
            media.microphoneGain = options.microphoneGain
            return media
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
