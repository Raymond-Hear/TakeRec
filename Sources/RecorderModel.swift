import AppKit
@preconcurrency import AVFoundation
import Combine
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureTarget: String, CaseIterable, Identifiable, Codable {
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
    @Published private(set) var stoppedCameras: Set<TrackKind> = []
    @Published private(set) var recordingLevels: [Double] = []
    @Published private(set) var controlsVisible = false
    @Published private(set) var promptVisible = false
    @Published private(set) var cameras: [CameraSource] = []
    @Published private(set) var microphones: [MicrophoneSource] = []
    @Published private(set) var sourceName: String?
    @Published private(set) var screenFrame: CGImage?
    @Published private(set) var cameraFrame: CGImage?
    @Published private(set) var additionalCameraFrames: [TrackKind: CGImage] = [:]
    @Published private(set) var cameraInputSize: String?
    @Published private(set) var maskState = FaceMaskState.waiting
    @Published private(set) var microphoneLevels: [Double] = []
    @Published private(set) var overlayActive = false
    @Published private(set) var liveKeyLabels: [String] = []
    @Published private(set) var isCapturingKeys = false
    @Published var showFullScreenToolsChoice = false

    @Published var target = CaptureTarget.window
    @Published var useMicrophone = false
    @Published var microphoneGain = 1.0
    @Published var useSystemAudio = false
    @Published var useCamera = false
    @Published var cursorAppearance = CursorAppearance.system
    @Published var recordClickEffects = true
    @Published var prioritizeNarration = true
    @Published var availableShortcuts: Set<ShortcutAction> = []
    @Published var activeShortcutLabels: [ShortcutAction: String] = [:]
    @Published var showRecordingStrip = true
    @Published private(set) var includesMenuBar = UserDefaults.standard.object(forKey: "TakeRec.Capture.IncludeMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includesMenuBar, forKey: "TakeRec.Capture.IncludeMenuBar") }
    }
    @Published var retainKeystrokes = UserDefaults.standard.bool(forKey: "TakeRec.Keyboard.Retain") {
        didSet { UserDefaults.standard.set(retainKeystrokes, forKey: "TakeRec.Keyboard.Retain") }
    }
    @Published var showKeystrokes = UserDefaults.standard.object(forKey: "TakeRec.Keyboard.Live") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showKeystrokes, forKey: "TakeRec.Keyboard.Live") }
    }
    @Published var keyboardMode = KeyboardDisplayMode(rawValue: UserDefaults.standard.string(forKey: "TakeRec.Keyboard.Mode") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(keyboardMode.rawValue, forKey: "TakeRec.Keyboard.Mode") }
    }
    @Published var keyboardCorner = CameraCorner.bottomLeft
    var recordingToolKeys: [ShortcutKey] = []
    @Published var cameraID = ""
    @Published private(set) var additionalCameraIDs: [TrackKind: String] = [:]
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
    let permissions = RecordingPermissions()
    #if !TAKEREC_STORE
    let phone = PhoneLink()
    private var phoneChanges: AnyCancellable?
    #endif
    private let panels = RecordingPanels()
    private let previewLighting = OSAllocatedUnfairLock(initialState: PortraitLighting())
    private var startedAt: CMTime?
    private var pauses = CapturePauseClock()
    private var lastAudioAt = ContinuousClock.now
    private var lastAudibleAt = ContinuousClock.now
    private var lastKeyAt = ContinuousClock.now

    private let picker = SCContentSharingPicker.shared
    private var source: ScreenSource?
    private var sourceID: UUID?
    private var take: ScreenTake?
    private var startingHardware = false
    private var startupInterruption: Error?
    private var deviceJob: Task<Void, Never>?
    private var deviceGeneration = 0
    private var cameraTests: [TrackKind: DeviceInput] = [:]
    private var micTest: DeviceInput?
    private var setupVisible = false
    private static let permissionSetupKey = "TakeRec.Permissions.RecordingSetup"

    private struct PermissionSetup: Codable {
        let target: CaptureTarget
        let camera: Bool
        let microphone: Bool
        let keyboard: Bool
        var retainKeyboard: Bool?
        let keyboardMode: KeyboardDisplayMode
        let keyboardCorner: CameraCorner
        let recordingStrip: Bool
        let cameraID: String
        let microphoneID: String
        var additionalCameras: [TrackKind: String]?
    }

    override init() {
        super.init()
        restoreSetupForPermissions()
        #if !TAKEREC_STORE
        phoneChanges = phone.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        #endif
        picker.add(self)
        picker.maximumStreamCount = 1
    }

    var canRecord: Bool {
        guard setupVisible && phase == .idle && !permissions.isPresented && source != nil && screenFrame != nil && !overlayActive &&
            activeCameraIDs.keys.allSatisfy({ frame(for: $0) != nil }) &&
            (!useMicrophone || !microphoneLevels.isEmpty) else { return false }
        #if !TAKEREC_STORE
        if phoneCameraSelected && !phone.hasVideo { return false }
        if useMicrophone && isPhoneInput(microphoneID) && !phone.hasAudio { return false }
        #endif
        return true
    }

    #if !TAKEREC_STORE
    func startPhonePairing() {
        guard phase == .idle else { return }
        phone.start()
        updateDeviceTests()
    }

    func usePhoneInputs() {
        if phone.hasVideo {
            additionalCameraIDs = additionalCameraIDs.filter { $0.value != PhoneLink.deviceID }
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
        additionalCameraIDs = additionalCameraIDs.filter { $0.value != PhoneLink.deviceID }
        if cameraID == PhoneLink.deviceID { cameraID = ""; useCamera = false }
        if microphoneID == PhoneLink.deviceID { microphoneID = ""; useMicrophone = false }
        refreshDevices()
    }

    func closeUnusedPhonePairing() {
        let phoneMicSelected = useMicrophone && microphoneID == PhoneLink.deviceID
        if !phoneCameraSelected && !phoneMicSelected {
            phone.stop()
        } else if (phoneCameraSelected && phone.hasVideo && !cameras.contains(where: { $0.id == PhoneLink.deviceID })) ||
                    (phoneMicSelected && phone.hasAudio && !microphones.contains(where: { $0.id == PhoneLink.deviceID })) {
            refreshDevices()
        }
    }
    #endif

    var activeCameraIDs: [TrackKind: String] {
        guard useCamera else { return [:] }
        var selected = additionalCameraIDs
        selected[.camera] = cameraID
        return selected
    }

    #if !TAKEREC_STORE
    var canAddPhoneCamera: Bool { phone.hasVideo && canAddCamera(PhoneLink.deviceID) }
    var phoneCameraSelected: Bool { activeCameraIDs.values.contains(PhoneLink.deviceID) }

    func addPhoneCamera() {
        addCamera(PhoneLink.deviceID)
        refreshDevices()
    }
    #endif

    private func stopPhoneLink() {
        #if !TAKEREC_STORE
        phone.stop()
        #endif
    }

    func canAddCamera(_ id: String) -> Bool {
        useCamera && !cameraID.isEmpty && additionalCameraIDs.count < TrackKind.cameraTracks.count - 1 &&
            !activeCameraIDs.values.contains(id)
    }

    func addCamera(_ id: String) {
        guard canAddCamera(id),
              let slot = TrackKind.cameraTracks.dropFirst().first(where: { additionalCameraIDs[$0] == nil }) else { return }
        additionalCameraIDs[slot] = id
    }

    func selectCamera(_ id: String, for kind: TrackKind) {
        guard !activeCameraIDs.contains(where: { $0.key != kind && $0.value == id }) else { return }
        if kind == .camera { cameraID = id }
        else if kind.isCamera { additionalCameraIDs[kind] = id }
    }

    func removeCamera(_ kind: TrackKind) {
        #if TAKEREC_STORE
        additionalCameraIDs.removeValue(forKey: kind)
        #else
        if additionalCameraIDs.removeValue(forKey: kind) == PhoneLink.deviceID { closeUnusedPhonePairing() }
        #endif
    }

    func frame(for kind: TrackKind) -> CGImage? {
        kind == .camera ? cameraFrame : additionalCameraFrames[kind]
    }

    func cameraName(for kind: TrackKind) -> String {
        guard let id = activeCameraIDs[kind] else { return kind.angleTitle }
        #if !TAKEREC_STORE
        if id == PhoneLink.deviceID { return PhoneLink.deviceName }
        #endif
        return cameras.first(where: { $0.id == id })?.name ?? kind.angleTitle
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

    func setIncludesMenuBar(_ value: Bool) {
        guard phase == .idle, value != includesMenuBar else { return }
        guard let source, isFullScreenSource else {
            includesMenuBar = value
            return
        }
        phase = .connecting
        notice = nil
        screenFrame = nil
        Task {
            do {
                try await source.setIncludesMenuBar(value)
                guard self.source === source, phase == .connecting else { return }
                includesMenuBar = value
            } catch {
                guard self.source === source, phase == .connecting else { return }
                notice = "无法调整顶部菜单栏。\(error.localizedDescription)"
            }
            phase = .idle
        }
    }

    private var captureCameraResolution: VideoResolution {
        portraitStyle.isFaceMask || isPhoneInput(cameraID) ? .hd : cameraResolution
    }

    var recordingPanelAvailability: RecordingPanelAvailability? { source?.panelAvailability }
    var isFullScreenSource: Bool { source?.filter.style == .display }
    var canShowRecordingPanels: Bool { phase == .recording && source?.protectsRecordingPanels == true }

    var recordingTime: String {
        guard let startedAt else { return "00:00" }
        let seconds = Int(pauses.elapsed(since: startedAt, at: CMClockGetTime(CMClockGetHostTimeClock())))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var cameraStatus: String {
        if let stopped = TrackKind.cameraTracks.first(where: stoppedCameras.contains) {
            return activeCameraIDs.count > 1 ? "\(stopped.angleTitle)已停止录制" : "摄像头已停止录制"
        }
        if activeCameraIDs.count > 1 { return "\(activeCameraIDs.count) 路机位录制中" }
        if useCamera, portraitStyle.isFaceMask { return maskState == .tracking ? "面具跟踪中" : "人像遮挡中" }
        return useCamera ? "摄像头已开启" : "摄像头未开启"
    }

    var cameraStopped: Bool { !stoppedCameras.isEmpty }

    var audioMeterTitle: String {
        if useMicrophone { return "麦克风" }
        return useSystemAudio ? "系统声音" : "音频未开启"
    }

    var visibleKeyLabels: [String] {
        isPaused || lastKeyAt.duration(to: .now) >= .seconds(1.6) ? [] : liveKeyLabels
    }

    var keyboardWaitingDescription: String {
        keyboardCaptureIssue?.recordingNotice ?? (isPaused ? "录制已暂停" : take?.keyboardWaitingDescription ?? "按键采集尚未开始")
    }

    var keyboardCaptureIssue: KeyboardCaptureIssue? { take?.keyboardIssue }

    func clearKeyDisplay() {
        guard phase == .recording, isCapturingKeys else { return }
        take?.clearKeyDisplay()
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
        teleprompter.recordingPaused = paused
        if paused { liveKeyLabels = [] }
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
        teleprompter.panelVisible = promptVisible
    }

    func recoverRecordingTools() {
        guard canShowRecordingPanels else { return }
        controlsVisible = panels.showControls(for: self, displayID: source?.panelDisplayID, recenter: true)
        showPrompt(recenter: true)
    }

    func hidePrompt() {
        panels.hidePrompt()
        promptVisible = false
        teleprompter.panelVisible = false
    }

    func togglePrompt() {
        if promptVisible { hidePrompt() }
        else { showPrompt() }
    }

    func turnPromptPage(_ delta: Int) {
        guard promptVisible else { return }
        teleprompter.step(delta)
    }

    func togglePromptScrolling() {
        guard promptVisible else { return }
        teleprompter.toggleScrolling()
    }

    var inputMonitoringAllowed: Bool { permissions.granted.contains(.keyboard) }
    var canRestartForPermissions: Bool { phase == .idle && editor == nil }

    func openPermissions(_ permission: RecordingPermission? = nil) {
        guard phase == .idle else { return }
        hidePrompt()
        permissions.open(focusing: permission)
        saveSetupForPermissions()
    }

    func requestPermission(_ permission: RecordingPermission) {
        saveSetupForPermissions()
        Task { await permissions.request(permission) }
    }

    func finishPermissions() {
        permissions.finish()
        UserDefaults.standard.removeObject(forKey: Self.permissionSetupKey)
        refreshPermissions()
        updateDeviceTests()
    }

    func refreshPermissions() {
        permissions.refresh()
        recheckFullScreenPanelsOnReturn()
    }

    func recheckPermissions() {
        permissions.recheck()
        recheckFullScreenPanelsOnReturn()
    }

    func restartForPermissions() {
        guard canRestartForPermissions, permissions.beginReopen() else { return }
        saveSetupForPermissions()
        Task {
            do {
                try await RecordingPermissions.launchReplacement(at: Bundle.main.bundleURL)
                NSApp.terminate(nil)
            } catch {
                permissions.failedToReopen()
            }
        }
    }

    private func saveSetupForPermissions() {
        let draft = PermissionSetup(target: target, camera: useCamera, microphone: useMicrophone, keyboard: showKeystrokes,
                                    retainKeyboard: retainKeystrokes,
                                    keyboardMode: keyboardMode, keyboardCorner: keyboardCorner, recordingStrip: showRecordingStrip,
                                    cameraID: cameraID, microphoneID: microphoneID, additionalCameras: additionalCameraIDs)
        UserDefaults.standard.set(try? PropertyListEncoder().encode(draft), forKey: Self.permissionSetupKey)
    }

    private func restoreSetupForPermissions() {
        guard permissions.isPresented,
              let data = UserDefaults.standard.data(forKey: Self.permissionSetupKey),
              let draft = try? PropertyListDecoder().decode(PermissionSetup.self, from: data) else { return }
        target = draft.target
        useCamera = draft.camera
        useMicrophone = draft.microphone
        showKeystrokes = draft.keyboard
        retainKeystrokes = draft.retainKeyboard ?? draft.keyboard
        keyboardMode = draft.keyboardMode
        keyboardCorner = draft.keyboardCorner
        showRecordingStrip = draft.recordingStrip
        cameraID = draft.cameraID
        microphoneID = draft.microphoneID
        additionalCameraIDs = (draft.additionalCameras ?? [:]).filter { $0.key.isCamera && $0.key != .camera }
    }

    func chooseWindowForRecording() {
        guard phase == .idle else { return }
        target = .window
        chooseSource()
    }

    func recheckFullScreenPanelAccess() {
        guard phase == .idle, let source, isFullScreenSource else { return }
        notice = nil
        phase = .connecting
        Task {
            source.refreshPanelAvailability()
            guard self.source === source, phase == .connecting else { return }
            if source.panelAvailability == .needsPermission {
                notice = "系统尚未对当前简录进程生效。若已在系统设置开启，请退出并重新打开这一版简录。"
            }
            phase = .idle
        }
    }

    func recheckFullScreenPanelsOnReturn() {
        guard phase == .idle, !permissions.reopening,
              recordingPanelAvailability == .needsPermission, CGPreflightScreenCaptureAccess() else { return }
        recheckFullScreenPanelAccess()
    }

    private func hideRecordingPanels() {
        panels.hideControls(release: true)
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
        stopPhoneLink()
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
        stopPhoneLink()
        Task {
            await releaseSource()
            await releaseDeviceTests()
            if phase == .choosing || phase == .connecting { phase = .idle }
        }
    }

    func refreshDevices() {
        cameras = CameraSource.devices().map { CameraSource(id: $0.uniqueID, name: $0.localizedName) }
        microphones = MicrophoneSource.devices().map { MicrophoneSource(id: $0.uniqueID, name: $0.localizedName) }
        #if !TAKEREC_STORE
        if phone.active && (phone.hasVideo || activeCameraIDs.values.contains(PhoneLink.deviceID)) {
            cameras.append(CameraSource(id: PhoneLink.deviceID, name: PhoneLink.deviceName))
        }
        if phone.active && (phone.hasAudio || microphoneID == PhoneLink.deviceID) {
            microphones.append(MicrophoneSource(id: PhoneLink.deviceID, name: PhoneLink.deviceName))
        }
        #endif
        if cameraID.isEmpty {
            cameraID = cameras.first(where: { !additionalCameraIDs.values.contains($0.id) })?.id ?? ""
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
        guard setupVisible, !permissions.isPresented, phase == .idle || phase == .choosing || phase == .connecting else { return }
        deviceGeneration += 1
        let generation = deviceGeneration
        let pending = deviceJob
        let cameras = activeCameraIDs
        let microphoneID = useMicrophone ? microphoneID : nil
        let portraitStyle = self.portraitStyle
        let primaryResolution = captureCameraResolution
        let previewLighting = self.previewLighting
        let lighting = currentLighting
        previewLighting.withLock { $0 = lighting }
        deviceNotice = nil
        cameraFrame = nil
        additionalCameraFrames = [:]
        cameraInputSize = nil
        maskState = .waiting
        microphoneLevels = []

        deviceJob = Task {
            await pending?.value
            guard generation == deviceGeneration else { return }
            await stopDevices()
            #if !TAKEREC_STORE
            var phoneVideo: ((CVPixelBuffer) -> Void)?
            var phoneAudio: ((CMSampleBuffer) -> Void)?
            #endif
            for kind in TrackKind.cameraTracks {
                guard let id = cameras[kind], generation == deviceGeneration else { continue }
                let style = kind == .camera ? portraitStyle : .camera
                do {
                    guard !id.isEmpty else { throw RecorderError.message("请连接并选择摄像头。") }
                    if !isPhoneInput(id) {
                        try requireAccess(to: .video, label: "摄像头")
                        guard generation == deviceGeneration else { return }
                    }
                    let decoder = PreviewImageDecoder(limit: kind == .camera ? 1280 : 640)
                    let queue = DispatchQueue(label: "local.desktake.camera-preview.\(kind.rawValue)")
                    let portrait = FaceMaskPortrait(style: style, resultQueue: queue, onState: { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.deviceGeneration == generation, self.portraitStyle == portraitStyle else { return }
                            self.maskState = state
                        }
                    }) { [weak self] buffer in
                        let lighting = style.isFaceMask ? PortraitLighting() : previewLighting.withLock { $0 }
                        if let image = decoder.frame(buffer, lighting: lighting) {
                            let size = "\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer))"
                            Task { @MainActor in
                                guard let self, self.deviceGeneration == generation, self.portraitStyle == portraitStyle else { return }
                                if kind == .camera {
                                    self.cameraFrame = image
                                    if self.cameraInputSize != size { self.cameraInputSize = size }
                                } else {
                                    self.additionalCameraFrames[kind] = image
                                }
                            }
                        }
                    }
                    if isPhoneInput(id) {
                        #if !TAKEREC_STORE
                        phoneVideo = { portrait.submit($0) }
                        #endif
                    } else {
                        let probe = DeviceInput(media: .video, outputQueue: queue,
                                                videoResolution: kind == .camera ? primaryResolution : .hd,
                                                video: { portrait.submit($0) })
                        cameraTests[kind] = probe
                        try await probe.select(id)
                    }
                } catch {
                    if generation == deviceGeneration {
                        deviceNotice = "\(cameraName(for: kind)) · \(error.localizedDescription)"
                    }
                }
            }
            if let id = microphoneID, generation == deviceGeneration {
                do {
                    guard !id.isEmpty else { throw RecorderError.message("请连接并选择麦克风。") }
                    if isPhoneInput(id) {
                        #if !TAKEREC_STORE
                        var lastLevel: ContinuousClock.Instant?
                        phoneAudio = { [weak self] sample in
                            guard let self, self.deviceGeneration == generation else { return }
                            let now = ContinuousClock.now
                            if let lastLevel, lastLevel.duration(to: now) < .milliseconds(44) { return }
                            lastLevel = now
                            let db = DeviceInput.decibels(sample) ?? -72
                            self.microphoneLevels = Array(self.microphoneLevels.suffix(51)) + [db]
                        }
                        #endif
                    } else {
                        try requireAccess(to: .audio, label: "麦克风")
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
            #if !TAKEREC_STORE
            if generation == deviceGeneration { phone.setOutputs(video: phoneVideo, audio: phoneAudio) }
            #endif
        }
    }

    private func stopDevices() async {
        #if !TAKEREC_STORE
        phone.setOutputs(video: nil, audio: nil)
        #endif
        let cameras = cameraTests
        let mic = micTest
        cameraTests = [:]
        micTest = nil
        async let stopMic: Void? = try? mic?.select(nil)
        for camera in cameras.values { try? await camera.select(nil) }
        _ = await stopMic
    }

    private func releaseDeviceTests() async {
        deviceGeneration += 1
        let pending = deviceJob
        deviceJob = nil
        await pending?.value
        await stopDevices()
        cameraFrame = nil
        additionalCameraFrames = [:]
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
        do {
            let source = try ScreenSource(selection: filter, includesMenuBar: includesMenuBar,
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
            source.refreshPanelAvailability()
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

    func startRecording(allowWithoutPanels: Bool = false) {
        guard canRecord, let source, let id = sourceID else { return }
        showFullScreenToolsChoice = false
        let options = CaptureOptions(cameraID: useCamera ? cameraID : nil,
                                     microphone: useMicrophone, systemAudio: useSystemAudio,
                                     cursorAppearance: cursorAppearance, recordClickEffects: recordClickEffects,
                                     microphoneID: useMicrophone ? microphoneID : nil,
                                     personShape: personShape, mirrorCamera: mirrorCamera,
                                     prioritizeNarration: prioritizeNarration, portraitStyle: portraitStyle,
                                     screenResolution: screenResolution,
                                     cameraResolution: captureCameraResolution,
                                     portraitLighting: useCamera && !portraitStyle.isFaceMask ? currentLighting : nil,
                                     microphoneGain: existingMicrophoneGain ?? microphoneGain,
                                     keyboard: retainKeystrokes
                                         ? KeyboardCaptureOptions(mode: keyboardMode, corner: keyboardCorner, showInEditorInitially: showKeystrokes)
                                         : nil,
                                     additionalCameras: useCamera ? additionalCameraIDs : [:],
                                     cameraNames: Dictionary(uniqueKeysWithValues: activeCameraIDs.keys.map { ($0, cameraName(for: $0)) }))
        let wantsPanels = showRecordingStrip || (teleprompter.showOnRecord && !teleprompter.pages.isEmpty)
        phase = .starting
        startingHardware = true
        notice = nil
        Task {
            do {
                source.refreshPanelAvailability()
                if let error = startupInterruption { throw error }
                if wantsPanels, !allowWithoutPanels, source.panelAvailability != .available {
                    startingHardware = false
                    phase = .idle
                    showFullScreenToolsChoice = true
                    reveal()
                    return
                }
                hideRecordingPanels()
                await releaseDeviceTests()
                if let error = startupInterruption { throw error }
                if wantsPanels, isFullScreenSource, source.panelAvailability == .available, !allowWithoutPanels {
                    let windowIDs = try panels.prepareForDisplayCapture(self, displayID: source.panelDisplayID)
                    try await source.protectRecordingPanels(windowIDs)
                    picker.isActive = false
                    if let error = startupInterruption { throw error }
                }
                if options.microphone, !isPhoneInput(options.microphoneID),
                   !MicrophoneSource.devices().contains(where: { $0.uniqueID == options.microphoneID }) {
                    throw RecorderError.message("所选麦克风已断开。")
                }
                let take = try ScreenTake(source: source, options: options, onStarted: { [weak self] hostTime in
                    self?.didStart(id: id, hostTime: hostTime)
                }, onInterruption: { [weak self] error in
                    Task { @MainActor in self?.interrupted(id: id, error: error) }
                }, onLevel: { [weak self] level in
                    Task { @MainActor in self?.receiveLevel(level, id: id) }
                }, onCameraStopped: { [weak self] kind in
                    guard let self, self.sourceID == id else { return }
                    self.stoppedCameras.insert(kind)
                }, onMaskState: { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.sourceID == id, self.phase == .starting || self.phase == .recording else { return }
                        self.maskState = state
                    }
                }, coversLocation: { [weak self] location in
                    self?.panels.coversQuartzPoint(location) ?? false
                }, recordingToolKeys: { [weak self] in
                    self?.recordingToolKeys ?? []
                }, onKeyPress: { [weak self] labels in
                    guard let self, self.sourceID == id, self.phase == .recording else { return }
                    self.lastKeyAt = .now
                    self.liveKeyLabels = labels
                })
                #if !TAKEREC_STORE
                take.setPhoneSource(phone)
                #endif
                self.take = take
                if source.filter.style == .display {
                    panels.parkSetupWindows()
                }
                try await take.start()
                startingHardware = false
                if let error = startupInterruption {
                    startupInterruption = nil
                    stop(reason: error)
                }
            } catch {
                hideRecordingPanels()
                await releaseSource()
                resetCapture()
                phase = .idle
                notice = "无法开始录制。\(error.localizedDescription)"
                reveal()
                updateDeviceTests()
            }
        }
    }

    private func requireAccess(to media: AVMediaType, label: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: media) == .authorized else {
            throw RecorderError.message("请从「权限设置」允许简录使用\(label)。")
        }
    }

    private func didStart(id: UUID, hostTime: Double) {
        guard sourceID == id, phase == .starting, startupInterruption == nil else { return }
        startedAt = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        resetAudioMeter()
        teleprompter.restart()
        isCapturingKeys = take?.hasKeyboardCapture == true
        phase = .recording
        if showRecordingStrip, canShowRecordingPanels { toggleRecordingStrip() }
        else { panels.hideControls() }
        if teleprompter.showOnRecord, canShowRecordingPanels { showPrompt() }
        else { hidePrompt() }
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
                    if !media.interruptedCameras.isEmpty {
                        let names = media.interruptedCameras.map { media.cameraNames[$0] ?? $0.angleTitle }.joined(separator: "、")
                        notes.append("\(names)已停止录制，已保留此前的人像和其余素材。")
                    }
                    let missing = media.missing + media.tracks.filter { kind in
                        !project.manifest.timelineClips.contains { $0.kind == kind }
                    }
                    if !missing.isEmpty {
                        notes.append("这段录制没有收到可用的\(missing.map(\.title).joined(separator: "、"))素材。")
                    }
                    if let keyboardNote = take.keyboardRecordingNotice { notes.append(keyboardNote) }
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
            stopPhoneLink()
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
        teleprompter.recordingPaused = false
        liveKeyLabels = []
        isCapturingKeys = false
        stoppedCameras = []
        resetAudioMeter()
        startingHardware = false
        startupInterruption = nil
    }

    func openProject() {
        guard phase == .idle, editor == nil else { return }
        hidePrompt()
        stopPhoneLink()
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
