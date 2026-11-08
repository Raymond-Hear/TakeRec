import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var shortcuts: ShortcutPreferences
    @State private var editingPrompt = false
    @State private var pairingPhone = false
    @State private var adjustingPortrait = false
    private let accent = Color(red: 0.79, green: 0.21, blue: 0.16)

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 8) {
                    preview
                    sourceControls
                    if model.phase != .recording { screenQuality }
                    if model.phase == .idle { inputPrivacy }
                }
                .frame(minWidth: 390, maxWidth: .infinity)
                VStack(spacing: 8) {
                    cameraControls
                    microphoneControls
                    otherInputs
                }
                .frame(width: 285)
                .disabled(model.phase != .idle)
            }
            if model.overlayActive {
                message("macOS 的人物前置已开启。请在系统录制菜单关闭它，再用本页的圆形人像。")
            } else if let notice = model.notice {
                message(notice)
            } else if let notice = model.deviceNotice {
                message(notice)
            }
            if model.phase == .idle, let availability = model.recordingPanelAvailability,
               let notice = availability.notice {
                HStack(spacing: 8) {
                    message(notice)
                    if availability == .needsPermission {
                        Button("允许全屏浮窗…") { model.requestFullScreenPanelAccess() }
                    } else if availability == .cannotExclude {
                        Button("重选来源…") { model.chooseSource() }
                    }
                }
            }
            Divider()
            footer
        }
        .padding(19)
        .frame(minWidth: 735, idealWidth: 820)
        .onAppear { model.showSetup() }
        .onDisappear { model.hideSetup() }
        .onChange(of: deviceSelection) { _, _ in model.updateDeviceTests() }
        .sheet(isPresented: $editingPrompt) {
            TeleprompterSettings(script: model.teleprompter, shortcuts: shortcuts, preview: { model.showPrompt() })
        }
        .sheet(isPresented: $pairingPhone, onDismiss: model.closeUnusedPhonePairing) {
            PhonePairingView(link: model.phone, useInputs: model.usePhoneInputs,
                             renew: model.startPhonePairing, disconnect: model.disconnectPhone)
        }
    }

    private var deviceSelection: [String] {
        [model.useCamera ? model.cameraID : "camera-off", model.useMicrophone ? model.microphoneID : "mic-off",
         model.portraitStyle.rawValue,
         model.useCamera && !model.portraitStyle.isFaceMask && model.cameraID != PhoneLink.deviceID ? model.cameraResolution.rawValue : ""]
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 45, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("简录").font(.title2.bold())
                    Text("TakeRec").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(model.isContinuing ? "这段录制会接到当前工程的时间线末尾。" : "先确认画面、相机与输入，再开始分轨录制。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .recording {
                Label(model.isPaused ? "已暂停" : "正在录制",
                      systemImage: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.headline).foregroundStyle(accent)
            } else {
                Button {
                    pairingPhone = true
                } label: {
                    Label("手机扫码…", systemImage: "qrcode")
                }
                .disabled(model.phase != .idle)
                Button {
                    model.hidePrompt()
                    editingPrompt = true
                } label: {
                    Label("提词器…", systemImage: "text.alignleft")
                }
                .disabled(model.phase != .idle)
                SettingsLink {
                    Label("快捷键设置", systemImage: "keyboard").labelStyle(.iconOnly)
                }
                .help("快捷键设置")
            }
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                if model.screenFrame == nil || model.phase == .recording {
                    Color(red: 0.045, green: 0.057, blue: 0.08)
                } else {
                    Color.secondary.opacity(0.06)
                }
                if model.phase == .recording {
                    recordingBadge
                } else if let screen = model.screenFrame {
                    let size = PreviewGeometry.fit(CGSize(width: screen.width, height: screen.height), in: geometry.size)
                    Image(decorative: screen, scale: 1).resizable().scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if model.useCamera, let camera = model.cameraFrame {
                                let edge = min(size.width, size.height)
                                cameraImage(camera, side: edge * 0.24).padding(edge * 0.032)
                            }
                        }
                } else if model.useCamera, let camera = model.cameraFrame {
                    VStack(spacing: 9) {
                        cameraImage(camera, side: min(geometry.size.width, geometry.size.height) * 0.64)
                        Text("摄像头预览").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    VStack(spacing: 9) {
                        DeskIcon("monitor", size: 35)
                        Text("屏幕预览").font(.headline)
                        Text("选好窗口或屏幕，画面会显示在这里。").font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(minHeight: 258)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel("录制内容预览")
    }

    private func cameraImage(_ image: CGImage, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * (model.personShape == .circle ? 0.5 : 0.18))
        return Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(x: model.mirrorCamera ? -1 : 1, y: 1)
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
            .frame(width: 148)
            Button(model.sourceName == nil ? "选择录制内容…" : "更换来源…") { model.chooseSource() }
            if let name = model.sourceName {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    model.clearSource()
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).help("关闭屏幕预览")
                .accessibilityLabel("关闭屏幕预览")
            }
            Spacer(minLength: 0)
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
            Text("建议优先使用 Mac 的摄像头和麦克风，启用时按系统提示授权，录制素材保存在本机。需要手机机位时，可先查看「手机扫码」里的隐私说明。")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var cameraControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("录制摄像头", isOn: $model.useCamera)
                if model.useCamera {
                    Picker("设备", selection: $model.cameraID) {
                        if model.cameraID.isEmpty { Text("选择摄像头").tag("") }
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    Picker("人像画面", selection: $model.portraitStyle) {
                        ForEach(PortraitStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if !model.portraitStyle.isFaceMask && model.cameraID != PhoneLink.deviceID {
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
                    }
                    HStack {
                        if !model.portraitStyle.isFaceMask && !model.isContinuing {
                            Button("人像调光…") { adjustingPortrait = true }
                                .controlSize(.small)
                                .popover(isPresented: $adjustingPortrait) { portraitLightingPopover }
                        }
                        Spacer(minLength: 0)
                        if let size = model.cameraInputSize {
                            Text("输入 \(size)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(model.portraitStyle.isFaceMask ? model.maskState.message :
                         (model.isContinuing ? "人像会沿用当前工程的布局和镜像。" : "人像和屏幕各录一轨，可在编辑器里移动。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        } label: {
            Label { Text("摄像头") } icon: { DeskIcon("video") }
        }
    }

    private var portraitLightingPopover: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let frame = model.cameraFrame {
                cameraImage(frame, side: 134).frame(maxWidth: .infinity)
            }
            PortraitLightingControls(lighting: $model.portraitLighting)
            Text("调整会在预览和成片中生效。原始人像分轨仍可在录后重新调光。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 278)
    }

    private var microphoneControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("录制麦克风", isOn: $model.useMicrophone)
                if model.useMicrophone {
                    Picker("输入", selection: $model.microphoneID) {
                        if model.microphoneID.isEmpty { Text("选择麦克风").tag("") }
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    }
                    InputMeter(levels: model.microphoneLevels, phone: model.microphoneID == PhoneLink.deviceID)
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
                    Text("建议用耳机或耳麦，减少外放声串入麦克风。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        } label: {
            Label { Text("麦克风") } icon: { DeskIcon("mic") }
        }
    }

    private var otherInputs: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("录制系统声音", isOn: $model.useSystemAudio)
                if model.useSystemAudio && model.useMicrophone && !model.isContinuing {
                    Toggle("人声优先", isOn: $model.prioritizeNarration)
                }
                Picker("光标", selection: $model.cursorAppearance) {
                    ForEach(CursorAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("需要录后更换光标时，录制前选「可编辑样式」。")
                Toggle("记录点击与运镜", isOn: $model.recordClickEffects)
                Toggle("录制时显示浮条", isOn: $model.showRecordingStrip)
                Button("刷新设备列表") { model.refreshDevices() }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        } label: {
            Label { Text("录制选项") } icon: { DeskIcon("audio-lines") }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Button {
                    model.startRecording()
                } label: {
                    Label("开始录制", systemImage: "record.circle")
                }
                .buttonStyle(DeskPrimaryButton(color: accent))
                .keyboardShortcut(.defaultAction).disabled(!model.canRecord)
                if model.isContinuing {
                    Button("返回当前工程") { model.returnToEditor() }
                } else {
                    Button("打开工程 / MP4…") { model.openProject() }
                }
            case .recording:
                EmptyView()
            case .choosing:
                Text(model.phase.title).font(.callout)
            default:
                ProgressView().controlSize(.small)
                Text(model.phase.title).font(.callout)
            }
            Spacer()
            if model.phase == .idle {
                Text(shortcutHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

    var body: some View {
        VStack(spacing: 4) {
            AudioLevelBars(levels: levels)
                .frame(height: 32)
                .padding(5)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(levels.isEmpty ? "正在等待输入" : (phone ? "手机输入峰值" : "麦克风输入峰值"))
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
