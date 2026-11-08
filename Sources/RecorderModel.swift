import AppKit
@preconcurrency import AVFoundation
import Combine
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureTarget: String, CaseIterable, Identifiable {
    case window = "单窗口"
    case display = "全屏"
    var id: Self { self }
}

@MainActor
final class RecorderModel: NSObject, ObservableObject, SCContentSharingPickerObserver {
    enum Phase {
        case idle, choosing, connecting, starting, recording, finishing, ready, opening

        var title: String {
            switch self {
            case .idle: "准备录制"
            case .choosing: "选择录制内容"
            case .connecting: "正在连接屏幕预览"
            case .starting: "正在开始录制"
            case .recording: "正在录制"
            case .finishing: "正在整理录制"
            case .ready: "录制编辑"
            case .opening: "正在打开素材"
            }
        }
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var notice: String?
    @Published private(set) var deviceNotice: String?
    @Published private(set) var editor: TakeEditorModel?
    @Published private(set) var isPaused = false
    @Published private(set) var cameraStopped = false
    @Published private(set) var recordingLevels: [Double] = []
    @Published private(set) var controlsVisible = false
    @Published private(set) var promptVisible = false
    @Published private(set) var cameras: [CameraSource] = []
    @Published private(set) var microphones: [MicrophoneSource] = []
    @Published private(set) var sourceName: String?
    @Published private(set) var screenFrame: CGImage?
    @Published private(set) var cameraFrame: CGImage?
    @Published private(set) var cameraInputSize: String?
    @Published private(set) var maskState = FaceMaskState.waiting
    @Published private(set) var microphoneLevels: [Double] = []
    @Published private(set) var overlayActive = false

    @Published var target = CaptureTarget.window
    @Published var useMicrophone = false
    @Published var microphoneGain = 1.0
    @Published var useSystemAudio = false
    @Published var useCamera = false
    @Published var cursorAppearance = CursorAppearance.system
    @Published var recordClickEffects = true
    @Published var prioritizeNarration = true
    @Published var availableShortcuts: Set<ShortcutAction> = []
    @Published var showRecordingStrip = true
    @Published var cameraID = ""
    @Published var microphoneID = ""
    @Published var personShape = CameraShape.circle
    @Published var mirrorCamera = false
    @Published var portraitStyle = PortraitStyle.camera {
        didSet {
            guard portraitStyle != oldValue else { return }
            cameraFrame = nil
            maskState = .waiting
        }
    }
    @Published var screenResolution = VideoResolution.uhd
    @Published var cameraResolution = VideoResolution.hd
    @Published var portraitLighting = PortraitLighting() {
        didSet {
            let lighting = currentLighting
            previewLighting.withLock { $0 = lighting }
        }
    }

    let teleprompter = TeleprompterScript()
    let phone = PhoneLink()
    private let panels = RecordingPanels()
    private let previewLighting = OSAllocatedUnfairLock(initialState: PortraitLighting())
    private var startedAt: CMTime?
    private var pauses = CapturePauseClock()
    private var lastAudioAt = ContinuousClock.now
    private var lastAudibleAt = ContinuousClock.now

    private let picker = SCContentSharingPicker.shared
    private var source: ScreenSource?
    private var sourceID: UUID?
    private var take: ScreenTake?
    private var startingHardware = false
    private var startupInterruption: Error?
    private var deviceJob: Task<Void, Never>?
    private var deviceGeneration = 0
    private var cameraTest: DeviceInput?
    private var micTest: DeviceInput?
    private var setupVisible = false
    private var phoneChanges: AnyCancellable?

    override init() {
        super.init()
        phoneChanges = phone.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        picker.add(self)
        picker.maximumStreamCount = 1
    }

    var canRecord: Bool {
        setupVisible && phase == .idle && source != nil && screenFrame != nil && !overlayActive &&
            (!useCamera || (cameraFrame != nil && (cameraID != PhoneLink.deviceID || phone.hasVideo))) &&
            (!useMicrophone || (!microphoneLevels.isEmpty && (microphoneID != PhoneLink.deviceID || phone.hasAudio)))
    }

    func startPhonePairing() {
        guard phase == .idle else { return }
        phone.start()
        updateDeviceTests()
    }

    func usePhoneInputs() {
        if phone.hasVideo {
            cameraID = PhoneLink.deviceID
            useCamera = true
        }
        if phone.hasAudio {
            microphoneID = PhoneLink.deviceID
            useMicrophone = true
        }
        refreshDevices()
    }

    func disconnectPhone() {
        phone.stop()
        if cameraID == PhoneLink.deviceID { cameraID = ""; useCamera = false }
        if microphoneID == PhoneLink.deviceID { microphoneID = ""; useMicrophone = false }
        refreshDevices()
    }

    func closeUnusedPhonePairing() {
        if cameraID != PhoneLink.deviceID && microphoneID != PhoneLink.deviceID { phone.stop() }
    }

    var isContinuing: Bool { editor != nil && phase != .ready }

    var existingMicrophoneGain: Double? {
        guard isContinuing, let manifest = editor?.manifest, manifest.tracks.contains(.microphone) else { return nil }
        return manifest.edit(.microphone).volume
    }

    private var currentLighting: PortraitLighting {
        isContinuing ? (editor?.manifest.effects.portraitLighting ?? PortraitLighting()) : portraitLighting
    }

    var screenSourceSize: CaptureSize? { try? source?.pixelSize() }
    var recordingSize: CaptureSize? { try? source?.size(for: screenResolution) }

    private var captureCameraResolution: VideoResolution {
        portraitStyle.isFaceMask || cameraID == PhoneLink.deviceID ? .hd : cameraResolution
    }

    var recordingPanelAvailability: RecordingPanelAvailability? { source?.panelAvailability }
    var canShowRecordingPanels: Bool { phase == .recording && recordingPanelAvailability == .available }

    var recordingTime: String {
        guard let startedAt else { return "00:00" }
        let seconds = Int(pauses.elapsed(since: startedAt, at: CMClockGetTime(CMClockGetHostTimeClock())))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var cameraStatus: String {
        if cameraStopped { return "摄像头已停止录制" }
        if useCamera, portraitStyle.isFaceMask { return maskState == .tracking ? "面具跟踪中" : "人像遮挡中" }
        return useCamera ? "摄像头已开启" : "摄像头未开启"
    }

    var audioMeterTitle: String {
        if useMicrophone { return "麦克风" }
        return useSystemAudio ? "系统声音" : "音频未开启"
    }

    var audioWarning: String? {
        guard phase == .recording, !isPaused, useMicrophone || useSystemAudio else { return nil }
        let now = ContinuousClock.now
        if lastAudioAt.duration(to: now) > .seconds(2) { return "未收到音频样本" }
        if recordingLevels.suffix(8).filter({ $0 >= -3 }).count >= 3 { return "电平偏高 · 调低输入音量" }
        if useMicrophone, lastAudibleAt.duration(to: now) > .seconds(6) { return "麦克风持续低电平" }
        return nil
    }

    func togglePause() {
        guard phase == .recording, let take else { return }
        let paused = !isPaused
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        take.setPaused(paused, at: time)
        pauses.setPaused(paused, at: time)
        if !paused { resetAudioMeter() }
        isPaused = paused
    }

    func toggleRecordingStrip() {
        guard canShowRecordingPanels else { return }
        if controlsVisible {
            panels.hideControls()
            controlsVisible = false
        } else {
            controlsVisible = panels.showControls(for: self, displayID: source?.panelDisplayID)
        }
    }

    func showPrompt(recenter: Bool = false) {
        guard (phase == .idle && setupVisible) || canShowRecordingPanels,
              !teleprompter.pages.isEmpty else { return }
        promptVisible = panels.showPrompt(teleprompter, displayID: source?.panelDisplayID, recenter: recenter) { [weak self] in
            self?.hidePrompt()
        }
    }

    func recoverRecordingTools() {
        guard canShowRecordingPanels else { return }
        controlsVisible = panels.showControls(for: self, displayID: source?.panelDisplayID, recenter: true)
        showPrompt(recenter: true)
    }

    func hidePrompt() {
        panels.hidePrompt()
        promptVisible = false
    }

    func togglePrompt() {
        if promptVisible { hidePrompt() }
        else { showPrompt() }
    }

    func turnPromptPage(_ delta: Int) {
        guard promptVisible else { return }
        teleprompter.step(delta)
    }

    func requestFullScreenPanelAccess() {
        guard phase == .idle, recordingPanelAvailability == .needsPermission else { return }
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            target = .display
            chooseSource()
        } else {
            notice = "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许简录，再重新打开。"
        }
    }

    private func hideRecordingPanels() {
        panels.hideControls()
        controlsVisible = false
        hidePrompt()
    }

    private func resetAudioMeter() {
        recordingLevels = []
        lastAudioAt = .now
        lastAudibleAt = lastAudioAt
    }

    func continueRecording() {
        guard phase == .ready, let editor, !editor.isBusy else { return }
        editor.pauseForRecording()
        personShape = editor.manifest.effects.cameraShape
        mirrorCamera = editor.manifest.effects.cameraMirrored
        notice = nil
        phase = .idle
    }

    func returnToEditor() {
        guard phase == .idle, isContinuing else { return }
        phone.stop()
        phase = .finishing
        Task {
            await releaseSource()
            await releaseDeviceTests()
            phase = .ready
        }
    }

    func showSetup() {
        setupVisible = true
        refreshDevices()
    }

    func hideSetup() {
        setupVisible = false
        guard phase == .idle || phase == .choosing || phase == .connecting else { return }
        hidePrompt()
        phone.stop()
        Task {
            await releaseSource()
            await releaseDeviceTests()
            if phase == .choosing || phase == .connecting { phase = .idle }
        }
    }

    func refreshDevices() {
        cameras = CameraSource.devices().map { CameraSource(id: $0.uniqueID, name: $0.localizedName) }
        microphones = MicrophoneSource.devices().map { MicrophoneSource(id: $0.uniqueID, name: $0.localizedName) }
        if phone.active && (phone.hasVideo || cameraID == PhoneLink.deviceID) {
            cameras.append(CameraSource(id: PhoneLink.deviceID, name: PhoneLink.deviceName))
        }
        if phone.active && (phone.hasAudio || microphoneID == PhoneLink.deviceID) {
            microphones.append(MicrophoneSource(id: PhoneLink.deviceID, name: PhoneLink.deviceName))
        }
        if cameraID.isEmpty {
            cameraID = cameras.first?.id ?? ""
        } else if !cameras.contains(where: { $0.id == cameraID }) {
            cameraID = ""
        }
        if microphoneID.isEmpty {
            microphoneID = microphones.first?.id ?? ""
        } else if !microphones.contains(where: { $0.id == microphoneID }) {
            microphoneID = ""
        }
        updateDeviceTests()
    }

    func updateDeviceTests() {
        guard setupVisible, phase == .idle || phase == .choosing || phase == .connecting else { return }
        deviceGeneration += 1
        let generation = deviceGeneration
        let pending = deviceJob
        let cameraID = useCamera ? cameraID : nil
        let microphoneID = useMicrophone ? microphoneID : nil
        let portraitStyle = self.portraitStyle
        let cameraResolution = captureCameraResolution
        let previewLighting = self.previewLighting
        let lighting = currentLighting
        previewLighting.withLock { $0 = lighting }
        deviceNotice = nil
        cameraFrame = nil
        cameraInputSize = nil
        maskState = .waiting
        microphoneLevels = []

        deviceJob = Task {
            await pending?.value
            guard generation == deviceGeneration else { return }
            await stopDevices()
            var phoneVideo: ((CVPixelBuffer) -> Void)?
            var phoneAudio: ((CMSampleBuffer) -> Void)?
            if let id = cameraID, generation == deviceGeneration {
                do {
                    guard !id.isEmpty else { throw RecorderError.message("请连接并选择摄像头。") }
                    if id != PhoneLink.deviceID {
                        try await requireAccess(to: .video, label: "摄像头")
                        guard generation == deviceGeneration else { return }
                    }
                    let decoder = PreviewImageDecoder(limit: 1280)
                    let queue = DispatchQueue(label: "local.desktake.camera-preview")
                    let portrait = FaceMaskPortrait(style: portraitStyle, resultQueue: queue, onState: { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.deviceGeneration == generation, self.portraitStyle == portraitStyle else { return }
                            self.maskState = state
                        }
                    }) { [weak self] buffer in
                        let lighting = portraitStyle.isFaceMask ? PortraitLighting() : previewLighting.withLock { $0 }
                        if let image = decoder.frame(buffer, lighting: lighting) {
                            let size = "\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer))"
                            Task { @MainActor in
                                guard let self, self.deviceGeneration == generation, self.portraitStyle == portraitStyle else { return }
                                self.cameraFrame = image
                                if self.cameraInputSize != size { self.cameraInputSize = size }
                            }
                        }
                    }
                    if id == PhoneLink.deviceID {
                        phoneVideo = { portrait.submit($0) }
                    } else {
                        let probe = DeviceInput(media: .video, outputQueue: queue, videoResolution: cameraResolution,
                                                video: { portrait.submit($0) })
                        cameraTest = probe
                        try await probe.select(id)
                    }
                } catch {
                    if generation == deviceGeneration { deviceNotice = error.localizedDescription }
                }
            }
            if let id = microphoneID, generation == deviceGeneration {
                do {
                    guard !id.isEmpty else { throw RecorderError.message("请连接并选择麦克风。") }
                    if id == PhoneLink.deviceID {
                        var lastLevel: ContinuousClock.Instant?
                        phoneAudio = { [weak self] sample in
                            guard let self, self.deviceGeneration == generation else { return }
                            let now = ContinuousClock.now
                            if let lastLevel, lastLevel.duration(to: now) < .milliseconds(44) { return }
                            lastLevel = now
                            let db = DeviceInput.decibels(sample) ?? -72
                            self.microphoneLevels = Array(self.microphoneLevels.suffix(51)) + [db]
                        }
                    } else {
                        try await requireAccess(to: .audio, label: "麦克风")
                        guard generation == deviceGeneration else { return }
                        let probe = DeviceInput(media: .audio, outputQueue: DispatchQueue(label: "local.desktake.mic-test"),
                                                level: { [weak self] db in
                            Task { @MainActor in
                                guard let self, self.deviceGeneration == generation else { return }
                                self.microphoneLevels = Array(self.microphoneLevels.suffix(51)) + [db]
                            }
                        })
                        micTest = probe
                        try await probe.select(id)
                    }
                } catch {
                    if generation == deviceGeneration { deviceNotice = error.localizedDescription }
                }
            }
            if generation == deviceGeneration { phone.setOutputs(video: phoneVideo, audio: phoneAudio) }
        }
    }

    private func stopDevices() async {
        phone.setOutputs(video: nil, audio: nil)
        let camera = cameraTest
        let mic = micTest
        cameraTest = nil
        micTest = nil
        async let stopCamera: Void? = try? camera?.select(nil)
        async let stopMic: Void? = try? mic?.select(nil)
        _ = await (stopCamera, stopMic)
    }

    private func releaseDeviceTests() async {
        deviceGeneration += 1
        let pending = deviceJob
        deviceJob = nil
        await pending?.value
        await stopDevices()
        cameraFrame = nil
        cameraInputSize = nil
        microphoneLevels = []
    }

    func chooseSource() {
        guard phase == .idle else { return }
        hidePrompt()
        notice = nil
        phase = .choosing
        let mode = target
        Task {
            await releaseSource()
            guard phase == .choosing, setupVisible else { return }
            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = mode == .window ? [.singleWindow] : [.singleDisplay]
            config.allowsChangingSelectedContent = false
            config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
            picker.defaultConfiguration = config
            picker.isActive = true
            picker.present(using: mode == .window ? .window : .display)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in self.cancelSelection() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.cancelSelection(error: error) }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        guard stream == nil else { return }
        Task { @MainActor in await self.connect(filter) }
    }

    private func cancelSelection(error: Error? = nil) {
        guard phase == .choosing else { return }
        picker.isActive = false
        phase = .idle
        if let error { notice = "无法打开录制选择器。\(error.localizedDescription)" }
    }

    private func connect(_ filter: SCContentFilter) async {
        guard phase == .choosing else { return }
        phase = .connecting
        let id = UUID()
        sourceID = id
        let displayID = ScreenSource.panelDisplayID(for: filter)
        let (selected, panelAvailability) = await ScreenSource.prepareSelection(filter)
        guard sourceID == id else { return }
        do {
            let source = try ScreenSource(filter: selected, panelAvailability: panelAvailability,
                                          panelDisplayID: displayID,
                                          onPreview: { [weak self] image in
                Task { @MainActor in
                    guard let self, self.sourceID == id, self.phase == .idle || self.phase == .connecting else { return }
                    self.screenFrame = image
                }
            }, onFailure: { [weak self] error in
                Task { @MainActor in self?.interrupted(id: id, error: error) }
            }, onOverlay: { [weak self] active in
                Task { @MainActor in
                    guard let self, self.sourceID == id else { return }
                    self.overlayActive = active
                }
            })
            self.source = source
            try await source.startPreview()
            guard sourceID == id else {
                await source.stop()
                return
            }
            if #available(macOS 15.2, *), let title = filter.includedWindows.first?.title, !title.isEmpty {
                sourceName = title
            } else {
                sourceName = filter.style == .display ? "全屏" : "单窗口"
            }
            phase = .idle
        } catch {
            guard sourceID == id else { return }
            await releaseSource()
            phase = .idle
            notice = "无法预览所选画面。\(error.localizedDescription)"
        }
    }

    func clearSource() {
        guard phase == .idle else { return }
        phase = .connecting
        Task {
            await releaseSource()
            phase = .idle
        }
    }

    private func releaseSource() async {
        let previous = source
        source = nil
        sourceID = nil
        sourceName = nil
        screenFrame = nil
        overlayActive = false
        picker.isActive = false
        await previous?.stop()
    }

    func startRecording() {
        guard canRecord, let source, let id = sourceID else { return }
        let options = CaptureOptions(cameraID: useCamera ? cameraID : nil,
                                     microphone: useMicrophone, systemAudio: useSystemAudio,
                                     cursorAppearance: cursorAppearance, recordClickEffects: recordClickEffects,
                                     microphoneID: useMicrophone ? microphoneID : nil,
                                     personShape: personShape, mirrorCamera: mirrorCamera,
                                     prioritizeNarration: prioritizeNarration, portraitStyle: portraitStyle,
                                     screenResolution: screenResolution,
                                     cameraResolution: captureCameraResolution,
                                     portraitLighting: useCamera && !portraitStyle.isFaceMask ? currentLighting : nil,
                                     microphoneGain: existingMicrophoneGain ?? microphoneGain)
        hideRecordingPanels()
        phase = .starting
        startingHardware = true
        notice = nil
        Task {
            await releaseDeviceTests()
            do {
                if let error = startupInterruption { throw error }
                if options.microphone, options.microphoneID != PhoneLink.deviceID,
                   !MicrophoneSource.devices().contains(where: { $0.uniqueID == options.microphoneID }) {
                    throw RecorderError.message("所选麦克风已断开。")
                }
                let take = try ScreenTake(source: source, options: options, phone: phone, onStarted: { [weak self] hostTime in
                    self?.didStart(id: id, hostTime: hostTime)
                }, onInterruption: { [weak self] error in
                    Task { @MainActor in self?.interrupted(id: id, error: error) }
                }, onLevel: { [weak self] level in
                    Task { @MainActor in self?.receiveLevel(level, id: id) }
                }, onCameraStopped: { [weak self] in
                    guard let self, self.sourceID == id else { return }
                    self.cameraStopped = true
                }, onMaskState: { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.sourceID == id, self.phase == .starting || self.phase == .recording else { return }
                        self.maskState = state
                    }
                }, coversLocation: { [weak self] location in
                    self?.panels.coversQuartzPoint(location) ?? false
                })
                self.take = take
                if source.filter.style == .display {
                    if source.panelAvailability == .available {
                        // Hide only the regular UI. Hiding the application can move panels off the active Space.
                        panels.parkSetupWindows()
                    } else {
                        NSApp.hide(nil)
                    }
                }
                try await take.start()
                startingHardware = false
                if let error = startupInterruption {
                    startupInterruption = nil
                    stop(reason: error)
                }
            } catch {
                await releaseSource()
                resetCapture()
                phase = .idle
                notice = "无法开始录制。\(error.localizedDescription)"
                reveal()
                updateDeviceTests()
            }
        }
    }

    private func requireAccess(to media: AVMediaType, label: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: media) { return }
        default: break
        }
        throw RecorderError.message("请在「系统设置 → 隐私与安全性 → \(label)」中允许简录。")
    }

    private func didStart(id: UUID, hostTime: Double) {
        guard sourceID == id, phase == .starting, startupInterruption == nil else { return }
        startedAt = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        resetAudioMeter()
        phase = .recording
        if showRecordingStrip, canShowRecordingPanels { toggleRecordingStrip() }
        if teleprompter.showOnRecord, canShowRecordingPanels { showPrompt() }
    }

    private func receiveLevel(_ value: Double, id: UUID) {
        guard sourceID == id, phase == .recording, !isPaused else { return }
        let db = value.isFinite ? value : -72
        lastAudioAt = .now
        if db > -50 { lastAudibleAt = lastAudioAt }
        recordingLevels = Array(recordingLevels.suffix(51)) + [db]
    }

    private func interrupted(id: UUID, error: Error) {
        guard sourceID == id else { return }
        if startingHardware {
            startupInterruption = error
        } else if phase == .starting || phase == .recording {
            stop(reason: error)
        } else if phase == .idle || phase == .connecting {
            Task {
                guard sourceID == id else { return }
                await releaseSource()
                phase = .idle
                notice = "屏幕预览已结束。\(error.localizedDescription)"
            }
        }
    }

    func stop(reason: Error? = nil) {
        guard let take, phase == .recording || (phase == .starting && !startingHardware) else { return }
        phase = .finishing
        hideRecordingPanels()
        Task {
            do {
                let media = try await take.stop()
                do {
                    let project = try await TakeProject.fromRecording(media)
                    var notes: [String] = []
                    if let reason { notes.append("已保存中断前的录制。\(reason.localizedDescription)") }
                    if media.cameraInterrupted { notes.append("摄像头已停止录制，已保留此前的人像和其余素材。") }
                    let missing = media.missing + media.tracks.filter { kind in
                        !project.manifest.timelineClips.contains { $0.kind == kind }
                    }
                    if !missing.isEmpty {
                        notes.append("这段录制没有收到可用的\(missing.map(\.title).joined(separator: "、"))素材。")
                    }
                    let note = notes.isEmpty ? nil : notes.joined(separator: " ")
                    if let editor {
                        try editor.appendRecording(project, note: note)
                    } else {
                        editor = TakeEditorModel(project: project, note: note, checkMicrophone: media.tracks.contains(.microphone))
                    }
                } catch {
                    try? FileManager.default.removeItem(at: media.folder)
                    throw error
                }
            } catch {
                let message = "录制未能完成。\((reason ?? error).localizedDescription)"
                if let editor { editor.reportRecording(message) }
                else { notice = message }
            }
            phone.stop()
            await releaseSource()
            resetCapture()
            phase = editor == nil ? .idle : .ready
            reveal()
            if phase == .idle { updateDeviceTests() }
        }
    }

    private func resetCapture() {
        take = nil
        startedAt = nil
        pauses = CapturePauseClock()
        isPaused = false
        cameraStopped = false
        resetAudioMeter()
        startingHardware = false
        startupInterruption = nil
    }

    func openProject() {
        guard phase == .idle, editor == nil else { return }
        hidePrompt()
        phone.stop()
        let panel = NSOpenPanel()
        panel.title = "打开录屏工程或 MP4"
        panel.allowedContentTypes = [.deskTakeProject, .mpeg4Movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        phase = .opening
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                self.phase = .idle
                return
            }
            Task {
                do {
                    await self.releaseSource()
                    await self.releaseDeviceTests()
                    let project = try await TakeProject.load(url)
                    let note = project.manifest.flattened
                        ? "导入片按原片画面和声音编辑。用「添加焦点」为旧片加上运镜。"
                        : nil
                    self.editor = TakeEditorModel(project: project, note: note)
                    self.phase = .ready
                } catch {
                    self.notice = "无法打开。\(error.localizedDescription)"
                    self.phase = .idle
                    self.updateDeviceTests()
                }
            }
        }
    }

    func closeEditor() -> Bool {
        guard let editor, !editor.isBusy else { return false }
        if editor.hasUnsavedProject {
            let alert = NSAlert()
            alert.messageText = "这段工程还未保存"
            alert.informativeText = "返回编辑后可以保存素材和当前设置。"
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "丢弃这次编辑")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        editor.close()
        self.editor = nil
        notice = nil
        phase = .idle
        return true
    }

    func reveal() {
        NSApp.unhide(nil)
        panels.restoreSetupWindows()
        NSApp.activate()
    }
}
