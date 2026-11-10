import AVFoundation
import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var shortcuts: ShortcutPreferences
    @ObservedObject private var permissions: RecordingPermissions
    @State private var editingPrompt = false
    #if !TAKEREC_STORE
    @State private var pairingPhone = false
    #endif
    @State private var adjustingPortrait = false
    @State private var showingCaptureOptions = false

    init(model: RecorderModel, shortcuts: ShortcutPreferences) {
        self.model = model
        self.shortcuts = shortcuts
        _permissions = ObservedObject(wrappedValue: model.permissions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 0) {
                previewPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(WorkbenchStyle.line).frame(width: 1)
                inputPanel.frame(width: 270)
            }
            .workbenchPanel()
            if model.phase == .idle { inputPrivacy }
            if model.overlayActive {
                message("macOS 的人物前置已开启。请在系统录制菜单关闭它，再用本页的圆形人像。")
            } else if let notice = model.notice {
                message(notice)
            } else if let notice = model.deviceNotice {
                message(notice)
            }
            if model.phase == .idle, let availability = model.recordingPanelAvailability {
                if let notice = availability.notice {
                    HStack(spacing: 8) {
                        message(notice)
                        if availability == .needsPermission {
                            Button("授权全屏浮窗…") { model.openPermissions(.screen) }
                            Button("重新检查") { model.recheckFullScreenPanelAccess() }
                        } else if availability == .cannotExclude {
                            Button("重选屏幕…") {
                                model.target = .display
                                model.chooseSource()
                            }
                        }
                    }
                    .controlSize(.small)
                } else if model.isFullScreenSource {
                    Label("全屏授权已就绪。简录会在开录前排除浮窗。", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(minWidth: 735, idealWidth: 940, minHeight: 580)
        .background(WorkbenchStyle.workspace)
        .tint(WorkbenchStyle.accent)
        .onAppear { model.showSetup() }
        .onDisappear { model.hideSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification).receive(on: RunLoop.main)) { _ in
            if model.phase == .idle { model.refreshDevices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification).receive(on: RunLoop.main)) { _ in
            if model.phase == .idle { model.refreshDevices() }
        }
        .onChange(of: deviceSelection) { _, _ in model.updateDeviceTests() }
        .alert("本次全屏浮窗还未就绪", isPresented: $model.showFullScreenToolsChoice) {
            if model.recordingPanelAvailability == .needsPermission {
                Button("去授权…") { model.openPermissions(.screen) }
            }
            Button("改录单窗口…") { model.chooseWindowForRecording() }
            Button("继续录制，隐藏浮窗") { model.startRecording(allowWithoutPanels: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.recordingPanelAvailability?.notice ?? "")
        }
        .sheet(isPresented: $permissions.isPresented) {
            RecordingPermissionGuide(permissions: permissions, canRestart: model.canRestartForPermissions,
                                     restart: model.restartForPermissions, request: model.requestPermission,
                                     recheck: model.recheckPermissions, finish: model.finishPermissions)
        }
        .sheet(isPresented: $editingPrompt) {
            TeleprompterSettings(script: model.teleprompter, shortcuts: shortcuts, preview: { model.showPrompt() })
        }
        #if !TAKEREC_STORE
        .sheet(isPresented: $pairingPhone, onDismiss: model.closeUnusedPhonePairing) {
            PhonePairingView(link: model.phone, useInputs: model.usePhoneInputs,
                             canAddCamera: { model.canAddPhoneCamera }, addCamera: model.addPhoneCamera,
                             cameraSelected: { model.phoneCameraSelected },
                             renew: model.startPhonePairing, disconnect: model.disconnectPhone)
        }
        #endif
    }

    private var deviceSelection: [String] {
        TrackKind.cameraTracks.map { model.activeCameraIDs[$0] ?? "camera-off" } +
            [model.useMicrophone ? model.microphoneID : "mic-off", model.portraitStyle.rawValue,
             model.useCamera && !model.portraitStyle.isFaceMask && !isPhoneInput(model.cameraID) ? model.cameraResolution.rawValue : ""]
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: TakeRecBrand.icon)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 37, height: 37)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("简录").font(.title2.bold())
                    Text("TakeRec").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(model.isContinuing ? "续录将接到当前工程末尾。" : "录制准备")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .recording {
                Label(model.isPaused ? "已暂停" : "正在录制",
                      systemImage: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.headline).foregroundStyle(WorkbenchStyle.record)
            } else {
                #if !TAKEREC_STORE
                Button {
                    pairingPhone = true
                } label: {
                    Label("手机扫码…", systemImage: "qrcode")
                }
                .disabled(model.phase != .idle)
                #endif
                Button {
                    model.hidePrompt()
                    editingPrompt = true
                } label: {
                    Label("提词器…", systemImage: "text.alignleft")
                }
                .disabled(model.phase != .idle)
                Button {
                    model.openPermissions()
                } label: {
                    Label("权限设置", systemImage: "lock.shield").labelStyle(.iconOnly)
                }
                .help("权限设置")
                .accessibilityLabel("权限设置")
                .disabled(model.phase != .idle)
                SettingsLink {
                    Label("快捷键设置", systemImage: "keyboard").labelStyle(.iconOnly)
                }
                .help("快捷键设置")
                TakeRecAboutButton()
            }
        }
        .controlSize(.small)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase != .recording {
                sourceControls
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .controlSize(.small)
            }
            Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
            preview
            if model.phase != .recording {
                Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
                screenQuality
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .controlSize(.small)
            }
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("录制输入", systemImage: "slider.horizontal.3")
                .font(.headline)
                .padding(.horizontal, 12)
                .frame(height: 40)
            Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
            ViewThatFits(in: .vertical) {
                inputControls.fixedSize(horizontal: false, vertical: true)
                ScrollView { inputControls }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            cameraControls
            Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
            microphoneControls
            Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
            otherInputs
        }
        .padding(12)
        .controlSize(.small)
        .disabled(model.phase != .idle)
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                if model.phase == .recording {
                    Color(red: 0.045, green: 0.057, blue: 0.08)
                } else {
                    WorkbenchStyle.canvas
                }
                if model.phase == .recording {
                    recordingBadge
                } else if let screen = model.screenFrame {
                    let available = CGSize(width: max(0, geometry.size.width - 16),
                                           height: max(0, geometry.size.height - 20))
                    let size = PreviewGeometry.fit(CGSize(width: screen.width, height: screen.height), in: available)
                    Image(decorative: screen, scale: 1).resizable().scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .bottomTrailing) {
                            if model.useCamera {
                                let edge = min(size.width, size.height)
                                cameraPreviews(side: edge * 0.24).padding(edge * 0.032)
                            }
                        }
                } else if model.useCamera {
                    let count = CGFloat(max(1, model.activeCameraIDs.count))
                    let side = max(0, min(geometry.size.width / (count + 0.22), geometry.size.height * 0.57))
                    VStack(spacing: 9) {
                        cameraPreviews(side: side)
                        Text("摄像头预览").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("选择要录制的画面").font(.headline)
                        Text("在上方选择一个窗口或整块屏幕。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .accessibilityLabel("录制内容预览")
    }

    private func cameraPreviews(side: CGFloat) -> some View {
        let angles = TrackKind.cameraTracks.filter { model.activeCameraIDs[$0] != nil }
        return HStack(alignment: .top, spacing: 6) {
            ForEach(angles) { kind in
                VStack(spacing: 3) {
                    if let frame = model.frame(for: kind) {
                        cameraImage(frame, side: side, mirrored: kind == .camera && model.mirrorCamera)
                    } else {
                        RoundedRectangle(cornerRadius: side * 0.18)
                            .fill(.black.opacity(0.47)).frame(width: side, height: side)
                            .overlay {
                                Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.75))
                            }
                            .accessibilityLabel("\(kind.angleTitle)等待画面")
                    }
                    if angles.count > 1 {
                        Text(kind.angleTitle).font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.67), in: Capsule())
                    }
                }
                .help(model.cameraName(for: kind))
            }
        }
    }

    private func cameraImage(_ image: CGImage, side: CGFloat, mirrored: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * (model.personShape == .circle ? 0.5 : 0.18))
        return Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.65), lineWidth: 1)
            }
            .accessibilityLabel("人像预览")
    }

    private var recordingBadge: some View {
        VStack(spacing: 9) {
            Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .font(.system(size: 31)).foregroundStyle(model.isPaused ? Color.orange : Color.red)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(model.recordingTime).font(.system(size: 24, design: .monospaced)).foregroundStyle(.white)
            }
            Text(model.availableShortcuts.contains(.stop) ? "按 \(shortcuts[.stop].label) 结束录制" : "可从菜单栏结束录制")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
            if !model.controlsVisible {
                HStack {
                    Button(model.isPaused ? "继续" : "暂停") { model.togglePause() }
                    Button("结束录制") { model.stop() }
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }

    private var sourceControls: some View {
        HStack(spacing: 8) {
            Picker("范围", selection: $model.target) {
                ForEach(CaptureTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            .frame(width: 136)
            Button(model.sourceName == nil ? "选择录制内容…" : "更换来源…") { model.chooseSource() }
                .fixedSize()
            Spacer(minLength: 4)
            if let name = model.sourceName {
                Label(name, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(name)
                Button {
                    model.clearSource()
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).help("关闭屏幕预览")
                .accessibilityLabel("关闭屏幕预览")
            }
        }
        .disabled(model.phase != .idle)
    }

    private var screenQuality: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text("屏幕分辨率").font(.callout.weight(.medium))
                Picker("屏幕分辨率", selection: $model.screenResolution) {
                    ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 138)
                .help("选择屏幕录制的像素上限。简录保留所选画面的比例。")
                if model.target == .display || model.isFullScreenSource {
                    Spacer(minLength: 4)
                    Toggle("录制顶部菜单栏", isOn: Binding(
                        get: { model.includesMenuBar }, set: model.setIncludesMenuBar
                    ))
                    .toggleStyle(.checkbox)
                    .help("关闭后，全屏预览和成片会裁掉顶部菜单栏区域。")
                }
            }
            if let source = model.screenSourceSize, let recording = model.recordingSize {
                Text("实际录制 \(recording.pixelLabel) px · 来源 \(source.pixelLabel) px · 30 帧/秒")
                    .monospacedDigit()
            } else {
                Text("选择屏幕或窗口后，显示实际录制的像素尺寸。")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .disabled(model.phase != .idle)
    }

    private var inputPrivacy: some View {
        Label {
            Text(inputPrivacyText).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var inputPrivacyText: String {
        #if TAKEREC_STORE
        "素材保存在本机。开启摄像头或麦克风后，可以在这里预览画面和电平。"
        #else
        "建议优先使用 Mac 的摄像头和麦克风。素材保存在本机，连接手机前可查看「手机扫码」里的隐私说明。"
        #endif
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle("摄像头", isOn: $model.useCamera)
                Spacer(minLength: 4)
                if model.useCamera {
                    Button("人像设置…") { adjustingPortrait.toggle() }
                        .popover(isPresented: $adjustingPortrait) { portraitOptions }
                }
            }
            if model.useCamera {
                cameraPicker(.camera)
                ForEach(TrackKind.cameraTracks.dropFirst().filter { model.additionalCameraIDs[$0] != nil }) { kind in
                    HStack(spacing: 5) {
                        cameraPicker(kind)
                        Button { model.removeCamera(kind) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help("移除\(kind.angleTitle)")
                            .accessibilityLabel("移除\(kind.angleTitle)")
                    }
                }
                if !model.cameraID.isEmpty, model.activeCameraIDs.count < TrackKind.cameraTracks.count {
                    let available = model.cameras.filter { model.canAddCamera($0.id) }
                    Menu {
                        ForEach(available) { camera in
                            Button(camera.name) { model.addCamera(camera.id) }
                        }
                        #if TAKEREC_STORE
                        if available.isEmpty { Text("接入外接摄像头后可添加") }
                        #else
                        if !model.phoneCameraSelected {
                            Button("扫码连接手机…") { pairingPhone = true }
                        } else if available.isEmpty {
                            Text("接入外接摄像头后可添加")
                        }
                        #endif
                    } label: {
                        Label("添加机位", systemImage: "plus")
                    }
                    .fixedSize()
                }
                if model.activeCameraIDs.values.contains(where: { !isPhoneInput($0) }),
                   !permissions.granted.contains(.camera) {
                    Button("设置摄像头权限…") { model.openPermissions(.camera) }
                }
                if model.portraitStyle.isFaceMask {
                    Text(model.maskState.message).font(.caption).foregroundStyle(.secondary)
                } else if let size = model.cameraInputSize {
                    Text("主机位 \(size)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if model.activeCameraIDs.count > 1 {
                    Text("各机位独立录制，共用下方选择的麦克风。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cameraPicker(_ kind: TrackKind) -> some View {
        let selected = model.activeCameraIDs[kind] ?? ""
        let choices = model.cameras.filter { candidate in
            !model.activeCameraIDs.contains { $0.key != kind && $0.value == candidate.id }
        }
        return Picker(kind == .camera ? "主机位" : kind.angleTitle, selection: Binding(
            get: { selected }, set: { model.selectCamera($0, for: kind) }
        )) {
            if !choices.contains(where: { $0.id == selected }) {
                Text(disconnectedCameraLabel(selected)).tag(selected)
            }
            ForEach(choices) { Text($0.name).tag($0.id) }
        }
    }

    private func disconnectedCameraLabel(_ id: String) -> String {
        if id.isEmpty { return "选择摄像头" }
        #if !TAKEREC_STORE
        if isPhoneInput(id) { return "手机网页已断开" }
        #endif
        return "设备已断开"
    }

    private var portraitOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("人像设置", systemImage: "video").font(.headline)
            Picker("人像画面", selection: $model.portraitStyle) {
                ForEach(PortraitStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.activeCameraIDs.count > 1 {
                Text("面具样式和录前镜像用于主机位，新增机位最高 1080p。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.portraitStyle.isFaceMask && !isPhoneInput(model.cameraID) {
                Picker("摄像头分辨率", selection: $model.cameraResolution) {
                    ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("实际尺寸取决于所选摄像头支持的模式。")
            }
            if !model.isContinuing {
                Picker("人像前置", selection: $model.personShape) {
                    ForEach(CameraShape.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("镜像人像", isOn: $model.mirrorCamera)
                if !model.portraitStyle.isFaceMask {
                    Divider()
                    DisclosureGroup("人像调光") {
                        PortraitLightingControls(lighting: $model.portraitLighting).padding(.top, 6)
                    }
                }
            }
            Text(model.isContinuing ? "人像会沿用当前工程的布局和镜像。" : "屏幕与人像分开录制，位置和调光也能在录后修改。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .padding(14).frame(width: 298)
    }

    private var microphoneControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("麦克风", isOn: $model.useMicrophone)
            if model.useMicrophone {
                Picker("输入", selection: $model.microphoneID) {
                    if model.microphoneID.isEmpty { Text("选择麦克风").tag("") }
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }
                if !isPhoneInput(model.microphoneID), !permissions.granted.contains(.microphone) {
                    Button("设置麦克风权限…") { model.openPermissions(.microphone) }
                }
                InputMeter(levels: model.microphoneLevels, phone: isPhoneInput(model.microphoneID))
                if let gain = model.existingMicrophoneGain {
                    Text("沿用工程麦克风音量 \(Int((gain * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("麦克风增强", selection: $model.microphoneGain) {
                        Text("100%").tag(1.0)
                        Text("150%").tag(1.5)
                        Text("200%").tag(2.0)
                    }
                    .help("增强用于编辑预览和导出。录后可随时调整。")
                }
                Text("建议用耳机或耳麦减少外放串音。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherInputs: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("系统声音", isOn: $model.useSystemAudio)
            if model.useSystemAudio && model.useMicrophone && !model.isContinuing {
                Toggle("人声优先", isOn: $model.prioritizeNarration)
            }
            Toggle("显示录制控制条", isOn: $model.showRecordingStrip)
            Toggle("保留按键轨", isOn: $model.retainKeystrokes)
            if model.retainKeystrokes {
                Toggle("录制时显示键帽", isOn: $model.showKeystrokes)
                Picker("按键范围", selection: $model.keyboardMode) {
                    ForEach(KeyboardDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("展示位置", selection: $model.keyboardCorner) {
                    ForEach(CameraCorner.allCases) { Text($0.rawValue).tag($0) }
                }
                if !model.inputMonitoringAllowed {
                    Button("设置输入监控权限…") { model.openPermissions(.keyboard) }
                    Text("输入监控未就绪时可照常录屏，本次不保留按键。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.keyboardMode == .all
                     ? "工程会保留实际按键，实时显示可关闭。输入敏感信息前请暂停录制。"
                     : "工程只保留快捷键和操作键。剪辑时可开关按键轨。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("录制选项…") { showingCaptureOptions.toggle() }
                    .popover(isPresented: $showingCaptureOptions) {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("光标", selection: $model.cursorAppearance) {
                                ForEach(CursorAppearance.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .help("需要录后更换光标时，录制前选「可编辑样式」。")
                            Toggle("记录点击与运镜", isOn: $model.recordClickEffects)
                        }
                        .controlSize(.small)
                        .padding(14).frame(width: 258)
                    }
                Spacer(minLength: 4)
                Button("刷新设备") { model.refreshDevices() }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                if model.isContinuing {
                    Button("返回当前工程") { model.returnToEditor() }
                } else {
                    Button("打开工程 / MP4…") { model.openProject() }
                }
                Spacer(minLength: 8)
                if model.canRecord, model.retainKeystrokes, !model.inputMonitoringAllowed {
                    Label("本次不录按键", systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                }
                Text(shortcutHint).font(.caption).foregroundStyle(.secondary)
                Button {
                    model.startRecording()
                } label: {
                    Label("开始录制", systemImage: "record.circle")
                }
                .buttonStyle(DeskPrimaryButton(color: WorkbenchStyle.record))
                .keyboardShortcut(.defaultAction).disabled(!model.canRecord)
            case .recording:
                Spacer(minLength: 0)
            case .choosing:
                Text(model.phase.title).font(.callout)
            default:
                ProgressView().controlSize(.small)
                Text(model.phase.title).font(.callout)
            }
        }
        .controlSize(.small)
    }

    private var shortcutHint: String {
        var labels: [String] = []
        if model.availableShortcuts.contains(.start) { labels.append("开始 \(shortcuts[.start].label)") }
        if model.availableShortcuts.contains(.stop) { labels.append("结束 \(shortcuts[.stop].label)") }
        return labels.isEmpty ? "全局快捷键暂不可用" : labels.joined(separator: "  ·  ")
    }

    private func message(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InputMeter: View {
    let levels: [Double]
    let phone: Bool

    private var meterLabel: String {
        if levels.isEmpty { return "正在等待输入" }
        #if !TAKEREC_STORE
        if phone { return "手机输入峰值" }
        #endif
        return "麦克风输入峰值"
    }

    var body: some View {
        VStack(spacing: 4) {
            AudioLevelBars(levels: levels)
                .frame(height: 32)
                .padding(5)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(meterLabel)
                Spacer()
                if let db = levels.max() {
                    Text(String(format: "%.0f dBFS", db)).monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("麦克风实时电平")
    }
}

struct AudioLevelBars: View {
    let levels: [Double]
    private let bars = 52

    var body: some View {
        Canvas { context, size in
            let recent = levels.suffix(bars)
            let step = size.width / CGFloat(bars)
            for (index, db) in recent.enumerated() {
                let value = db.isFinite ? db : -72
                let strength = clamp((value + 60) / 60, 0, 1)
                let height = max(2, strength * size.height)
                let x = CGFloat(bars - recent.count + index) * step
                let path = Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2,
                                                    width: max(1, step - 1.4), height: height), cornerRadius: 1.2)
                let color: Color = value > -3 ? .red : value > -10 ? .orange : .teal
                context.fill(path, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
