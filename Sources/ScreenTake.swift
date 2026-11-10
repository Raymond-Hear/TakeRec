@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation
import os

private let screenPreviewLimit: CGFloat = 1920
private let screenLog = Logger(subsystem: "local.takerec.community", category: "ScreenCapture")

private final class ScreenSamples: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.desktake.screen", qos: .userInitiated)
    private let decoder = PreviewImageDecoder(limit: screenPreviewLimit)
    private let onPreview: @Sendable (CGImage) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let onOverlay: @Sendable (Bool) -> Void
    private let activeStream = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    private var recording: (writer: MovieWriter, size: CaptureSize)?
    private var delegateOverlay = false
    private var markedFrame = false
    private var isBlocked = false
    private var recordingInterrupted = false
    private var receivedMicrophone = false

    init(onPreview: @escaping @Sendable (CGImage) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void,
         onOverlay: @escaping @Sendable (Bool) -> Void) {
        self.onPreview = onPreview
        self.onFailure = onFailure
        self.onOverlay = onOverlay
    }

    func select(_ stream: SCStream?) {
        activeStream.withLock { $0 = stream.map(ObjectIdentifier.init) }
    }

    private func accepts(_ stream: SCStream) -> Bool {
        activeStream.withLock { $0 == ObjectIdentifier(stream) }
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

    func hasMicrophoneSamples() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.receivedMicrophone) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepts(stream) else { return }
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
            if CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 {
                receivedMicrophone = true
            }
            if !recordingInterrupted { recording?.writer.receiveAudio(sample, source: .microphone) }
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if accepts(stream) { onFailure(error) }
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        queue.async {
            guard self.accepts(stream) else { return }
            self.delegateOverlay = true
            self.updateOverlay()
        }
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        queue.async {
            guard self.accepts(stream) else { return }
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
        case .needsPermission: "请允许当前版本录制屏幕，简录才能在全屏录制时显示浮窗并把它们排除在成片外。"
        case .unsupported: "全屏录制控制条需要 macOS 15.2 或更新版本。也可以用单窗口录制。"
        case .cannotExclude: "当前画面无法排除简录浮窗。可以重选屏幕，或改为单窗口录制。"
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

    private let selection: SCContentFilter
    private(set) var filter: SCContentFilter
    private(set) var panelAvailability: RecordingPanelAvailability
    var protectsRecordingPanels: Bool { selection.style == .window || filter !== selection }
    let panelDisplayID: CGDirectDisplayID?
    private let menuBarHeight: CGFloat
    private var crop: CGRect?
    var croppedTop: CGFloat { crop?.minY ?? 0 }
    private var stream: SCStream
    private let samples: ScreenSamples
    private(set) var running = false
    var queue: DispatchQueue { samples.queue }
    var clock: CMClock? { stream.synchronizationClock }

    init(selection: SCContentFilter, includesMenuBar: Bool = true,
         onPreview: @escaping @Sendable (CGImage) -> Void = { _ in },
         onFailure: @escaping @Sendable (Error) -> Void,
         onOverlay: @escaping @Sendable (Bool) -> Void = { _ in }) throws {
        self.selection = selection
        filter = selection
        if selection.style == .window {
            panelAvailability = .available
        } else if #available(macOS 15.2, *) {
            panelAvailability = .cannotExclude
        } else {
            panelAvailability = .unsupported
        }
        let displayID = Self.panelDisplayID(for: selection)
        panelDisplayID = displayID
        let menuBarHeight = Self.menuBarHeight(on: displayID)
        self.menuBarHeight = menuBarHeight
        let crop = Self.menuBarCrop(for: selection, menuBarHeight: menuBarHeight, includesMenuBar: includesMenuBar)
        self.crop = crop
        let size = try CaptureSize(points: crop?.size ?? selection.contentRect.size, scale: CGFloat(selection.pointPixelScale),
                                   limit: screenPreviewLimit)
        samples = ScreenSamples(onPreview: onPreview, onFailure: onFailure, onOverlay: onOverlay)
        stream = SCStream(filter: selection, configuration: Self.configuration(size: size, options: nil, crop: crop),
                          delegate: samples)
        try stream.addStreamOutput(samples, type: .screen, sampleHandlerQueue: samples.queue)
        samples.select(stream)
    }

    func size(for resolution: VideoResolution) throws -> CaptureSize {
        try resolution.size(for: crop?.size ?? filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
    }

    func pixelSize() throws -> CaptureSize {
        try CaptureSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale),
                        limit: .greatestFiniteMagnitude)
    }

    func startPreview() async throws {
        try await stream.startCapture()
        running = true
    }

    func setIncludesMenuBar(_ included: Bool) async throws {
        guard running, filter.style == .display else { return }
        let next = Self.menuBarCrop(for: filter, menuBarHeight: menuBarHeight, includesMenuBar: included)
        guard next != crop else { return }
        let size = try CaptureSize(points: next?.size ?? filter.contentRect.size, scale: CGFloat(filter.pointPixelScale),
                                   limit: screenPreviewLimit)
        try await stream.updateConfiguration(Self.configuration(size: size, options: nil, crop: next))
        crop = next
    }

    func refreshPanelAvailability() {
        guard running, selection.style == .display, #available(macOS 15.2, *) else { return }
        panelAvailability = CGPreflightScreenCaptureAccess() ? .available : .needsPermission
    }

    func protectRecordingPanels(_ windowIDs: Set<CGWindowID>) async throws {
        guard #available(macOS 15.2, *), running, CGPreflightScreenCaptureAccess(),
              let display = selection.includedDisplays.first, !windowIDs.isEmpty else {
            throw RecorderError.message("全屏浮窗尚未就绪，请重新选择录制画面。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid || windowIDs.contains($0.windowID) }
        guard running, windowIDs.isSubset(of: Set(ownWindows.map(\.windowID))) else {
            panelAvailability = .cannotExclude
            throw RecorderError.message("系统没有返回全部录制浮窗，已取消本次录制。")
        }
        let protected = SCContentFilter(display: display, excludingWindows: ownWindows)
        protected.includeMenuBar = selection.includeMenuBar
        let size = try CaptureSize(points: crop?.size ?? protected.contentRect.size, scale: CGFloat(protected.pointPixelScale),
                                   limit: screenPreviewLimit)
        let recordingStream = SCStream(filter: protected, configuration: Self.configuration(size: size, options: nil, crop: crop),
                                       delegate: samples)
        try recordingStream.addStreamOutput(samples, type: .screen, sampleHandlerQueue: samples.queue)

        // The picker stream is only used for preview. A new stream starts with the actual panel IDs excluded.
        samples.select(nil)
        running = false
        try await stream.stopCapture()
        stream = recordingStream
        samples.select(stream)
        try await startPreview()
        filter = protected
        screenLog.notice("Started separate display stream excluding \(windowIDs.count) recording windows")
    }

    func startRecording(_ writer: MovieWriter, size: CaptureSize, options: CaptureOptions) async throws -> Bool {
        if options.systemAudio { try stream.addStreamOutput(samples, type: .audio, sampleHandlerQueue: samples.queue) }
        let config = Self.configuration(size: size, options: options, crop: crop)
        var capturesMicrophone = false
        if options.microphone, let id = options.microphoneID, !isPhoneInput(id) {
            do {
                try stream.addStreamOutput(samples, type: .microphone, sampleHandlerQueue: samples.queue)
                config.captureMicrophone = true
                config.microphoneCaptureDeviceID = id
                try await stream.updateConfiguration(config)
                capturesMicrophone = true
            } catch {
                // Devices that cannot join the screen stream can still use the capture session.
                try? stream.removeStreamOutput(samples, type: .microphone)
                config.captureMicrophone = false
                config.microphoneCaptureDeviceID = nil
            }
        }
        if !capturesMicrophone { try await stream.updateConfiguration(config) }
        try await samples.attach((writer, size))
        if !running {
            try await stream.startCapture()
            running = true
        }
        if capturesMicrophone {
            for _ in 0..<8 {
                if await samples.hasMicrophoneSamples() { return true }
                try await Task.sleep(for: .milliseconds(75))
            }
            try stream.removeStreamOutput(samples, type: .microphone)
            config.captureMicrophone = false
            config.microphoneCaptureDeviceID = nil
            try await stream.updateConfiguration(config)
        }
        return false
    }

    func stop() async {
        samples.select(nil)
        if running {
            running = false
            try? await stream.stopCapture()
        }
        try? await samples.attach(nil)
    }

    private static func menuBarHeight(on displayID: CGDirectDisplayID?) -> CGFloat {
        let screen = NSScreen.screens.first { $0.captureDisplayID == displayID }
        let reservedTop = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return max(NSStatusBar.system.thickness, reservedTop, screen?.safeAreaInsets.top ?? 0).rounded(.up)
    }

    private static func menuBarCrop(for filter: SCContentFilter, menuBarHeight: CGFloat, includesMenuBar: Bool) -> CGRect? {
        let size = filter.contentRect.size
        guard filter.style == .display, !includesMenuBar, menuBarHeight > 0, menuBarHeight < size.height else { return nil }
        return CGRect(x: 0, y: menuBarHeight, width: size.width, height: size.height - menuBarHeight)
    }

    private static func configuration(size: CaptureSize, options: CaptureOptions?, crop: CGRect?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        if let crop { config.sourceRect = crop }
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
    private let cameras: [TrackKind: DeviceInput]
    private let microphone: DeviceInput?
    #if !TAKEREC_STORE
    private let portrait: FaceMaskPortrait?
    private var phone: PhoneLink?
    #endif
    private let folder: URL
    private let pointer: PointerCapture?
    private var keyboard: KeyPressCapture?
    private(set) var keyboardIssue: KeyboardCaptureIssue?
    private let onStarted: @MainActor (Double) -> Void
    private let onInterruption: @Sendable (Error) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let onCameraStopped: @MainActor (TrackKind) -> Void
    private var acceptsPointer = false

    init(source: ScreenSource, options: CaptureOptions, onStarted: @escaping @MainActor (Double) -> Void,
         onInterruption: @escaping @Sendable (Error) -> Void, onLevel: @escaping @Sendable (Double) -> Void,
         onCameraStopped: @escaping @MainActor (TrackKind) -> Void, onMaskState: @escaping @Sendable (FaceMaskState) -> Void,
         coversLocation: @escaping (CGPoint) -> Bool,
         recordingToolKeys: @escaping () -> [ShortcutKey] = { [] },
         onKeyPress: @escaping ([String]) -> Void = { _ in }) throws {
        self.options = options
        self.source = source
        size = try source.size(for: options.screenResolution)
        self.onStarted = onStarted
        self.onInterruption = onInterruption
        self.onLevel = onLevel
        self.onCameraStopped = onCameraStopped
        folder = try TakeProject.temporaryFolder()
        do {
            let writer = try MovieWriter(folder: folder, size: size, options: options, queue: source.queue)
            self.writer = writer
            pointer = options.recordClickEffects || options.cursorAppearance == .editable
                ? PointerCapture(filter: source.filter, size: size, recordsClicks: options.recordClickEffects,
                                 croppedTop: source.croppedTop,
                                 coversLocation: coversLocation)
                : nil
            keyboard = options.keyboard.map {
                KeyPressCapture(options: $0, excludedShortcuts: recordingToolKeys, onPress: onKeyPress)
            }
            let portrait = options.cameraID != nil && options.portraitStyle.isFaceMask
                ? FaceMaskPortrait(style: options.portraitStyle, resultQueue: writer.queue,
                                   onState: onMaskState) { writer.receiveCamera($0) }
                : nil
            #if !TAKEREC_STORE
            self.portrait = portrait
            #endif
            cameras = Dictionary(uniqueKeysWithValues: options.cameras.compactMap { kind, id in
                guard !isPhoneInput(id) else { return nil }
                let input = DeviceInput(media: .video, outputQueue: writer.queue,
                                        videoResolution: options.resolution(for: kind), video: { buffer in
                    if kind == .camera, let portrait { portrait.submit(buffer) }
                    else { writer.receiveCamera(buffer, source: kind) }
                })
                return (kind, input)
            })
            microphone = options.microphone && !isPhoneInput(options.microphoneID)
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
            if let keyboard {
                do { try keyboard.prepare() }
                catch {
                    self.keyboard = nil
                    keyboardIssue = error
                }
            }
            #if !TAKEREC_STORE
            try attachPhone()
            #endif
            for kind in TrackKind.cameraTracks {
                guard let camera = cameras[kind], let id = options.cameras[kind] else { continue }
                do { try await camera.select(id) }
                catch {
                    let name = options.cameraNames[kind] ?? kind.angleTitle
                    throw RecorderError.message("\(name)未能启动。\(error.localizedDescription)")
                }
            }
            let streamCapturesMicrophone = try await source.startRecording(writer, size: size, options: options)
            if !streamCapturesMicrophone, let microphone, let id = options.microphoneID {
                try await microphone.select(id)
            }
            acceptsPointer = true
            writer.begin(clock: source.clock, onStarted: { [weak self] hostTime in
                Task { @MainActor in
                    guard let self, self.acceptsPointer else { return }
                    self.pointer?.start(at: hostTime)
                    if let keyboard = self.keyboard, !keyboard.start(at: hostTime) {
                        _ = keyboard.stop()
                        self.keyboard = nil
                        self.keyboardIssue = .unavailable
                    }
                    self.onStarted(hostTime)
                }
            }, onFailure: onInterruption, onLevel: onLevel, onCameraStopped: { [weak self] kind in
                Task { @MainActor in
                    guard let self, self.acceptsPointer else { return }
                    self.onCameraStopped(kind)
                    try? await self.cameras[kind]?.select(nil)
                }
            })
        } catch {
            _ = keyboard?.stop()
            #if !TAKEREC_STORE
            phone?.setOutputs(video: nil, audio: nil)
            #endif
            await source.stop()
            await stopDevices()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    #if !TAKEREC_STORE
    func setPhoneSource(_ phone: PhoneLink) {
        if options.cameras.values.contains(PhoneLink.deviceID) || isPhoneInput(options.microphoneID) {
            self.phone = phone
        }
    }

    private func attachPhone() throws {
        guard let phone else { return }
        var video: ((CVPixelBuffer) -> Void)?
        var audio: ((CMSampleBuffer) -> Void)?
        if let kind = options.cameras.first(where: { $0.value == PhoneLink.deviceID })?.key {
            guard phone.hasVideo else { throw RecorderError.message("请重新连接手机网页的摄像头。") }
            if kind == .camera, let portrait {
                video = { portrait.submit($0) }
            } else {
                video = { [writer] buffer in
                    let frame = PhoneVideoPacket(buffer: buffer)
                    writer.queue.async { writer.receiveCamera(frame.buffer, source: kind) }
                }
            }
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
    #endif

    private func stopDevices() async {
        for camera in cameras.values { try? await camera.select(nil) }
        try? await microphone?.select(nil)
    }

    func setPaused(_ paused: Bool, at hostTime: CMTime) {
        writer.setPaused(paused, at: hostTime)
        pointer?.setPaused(paused, at: hostTime)
        keyboard?.setPaused(paused, at: hostTime)
    }

    func clearKeyDisplay() {
        keyboard?.clear(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    var hasKeyboardCapture: Bool { keyboard != nil }
    var keyboardWaitingDescription: String? { keyboard?.waitingDescription }
    var keyboardRecordingNotice: String? { keyboardIssue?.recordingNotice ?? keyboard?.recordingNotice }

    func stop() async throws -> RecordedMedia {
        acceptsPointer = false
        #if !TAKEREC_STORE
        phone?.setOutputs(video: nil, audio: nil)
        #endif
        let trace = pointer?.stop() ?? PointerTrace()
        let keys = keyboard?.stop()
        async let draft = writer.finish()
        await source.stop()
        await stopDevices()
        do {
            var media = try await draft
            media.pointer = trace
            media.keyboard = keys
            media.showsKeyboard = keys == nil ? nil : options.keyboard?.showInEditorInitially
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
