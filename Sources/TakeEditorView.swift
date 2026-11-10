import AVKit
import CoreImage
import SwiftUI

struct TakeEditorView: View {
    @ObservedObject var editor: TakeEditorModel
    @ObservedObject var shortcuts: ShortcutPreferences
    let leave: () -> Void
    var continueRecording: () -> Void = {}
    @State private var showCursorMenu = false
    @State private var pickingFocus = false
    @State private var inspectorVisible = true
    @State private var inspectorTab = InspectorTab.picture
    @State private var pictureTab = PictureTab.clip
    @State private var layoutTab = CanvasInspector.Tab.background
    @State private var motionTab = MotionTab.zoom
    @State private var showLighting = false
    @State private var showMotionTiming = false
    @State private var showingTranscriptionTools = false
    @State private var showingAgentEditing = false
    @State private var tallTimeline = false
    @State private var timelineHeight: CGFloat?
    @GestureState private var dividerTranslation: CGFloat = 0
    @StateObject private var fullScreen = FullScreenPreview()

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case picture = "画面", motion = "运镜", audio = "声音", captions = "字幕"
        var id: Self { self }
        var icon: String {
            switch self {
            case .picture: "rectangle"
            case .motion: "scope"
            case .audio: "waveform"
            case .captions: "captions.bubble"
            }
        }
    }

    private enum PictureTab: String, CaseIterable, Identifiable {
        case clip = "片段", camera = "人像", keyboard = "键盘", layout = "画布"
        var id: Self { self }
    }

    private enum MotionTab: String, CaseIterable, Identifiable {
        case zoom = "点击运镜", cursor = "光标", click = "点击效果"
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            let inspectorWidth = min(288, max(260, geometry.size.width * 0.25))
            let naturalHeight = ClipTimelineView.laneContentHeight(trackCount: editor.manifest.tracks.count, tall: tallTimeline,
                                                                  keyboard: editor.manifest.hasKeyboardTrack)
            let minimum = min(125, naturalHeight)
            let maximum = min(naturalHeight, max(minimum, geometry.size.height - 325))
            let preferred = min(maximum, max(minimum, timelineHeight ?? maximum))
            let laneHeight = clamp(preferred - dividerTranslation, minimum, maximum)

            VStack(alignment: .leading, spacing: 0) {
                toolbar.padding(.bottom, 8)
                HStack(spacing: 0) {
                    viewer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorVisible {
                        Rectangle().fill(WorkbenchStyle.line).frame(width: 1)
                        inspector.frame(width: inspectorWidth)
                    }
                }
                .frame(maxHeight: .infinity)
                .workbenchPanel()
                if maximum > minimum {
                    timelineDivider(height: preferred, limits: minimum...maximum)
                } else {
                    Color.clear.frame(height: 10)
                }
                ClipTimelineView(editor: editor, shortcuts: shortcuts, maximumLaneHeight: laneHeight, tall: $tallTimeline,
                                 showSubtitles: showSubtitles)
                    .id(ObjectIdentifier(editor))
                if let activity = editor.activity {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, 6)
                } else if let notice = editor.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).padding(.top, 6)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 665)
        .background(WorkbenchStyle.workspace)
        .tint(WorkbenchStyle.accent)
        .disabled(editor.isBusy)
        .background(ShortcutEventMonitor(handle: handleKey))
        .onChange(of: tallTimeline) { _, _ in timelineHeight = nil }
        .onChange(of: editor.selectedTrack, initial: true) { _, track in
            pickingFocus = false
            inspectorTab = track.isVideo ? .picture : .audio
            pictureTab = track.isCamera ? .camera : (editor.canvas.framing == .portrait ? .layout : .clip)
        }
        .onChange(of: editor.selectedSubtitleID) { _, id in
            if id != nil { showSubtitles() }
        }
        .onChange(of: editor.selectedClipID) { _, _ in
            if editor.selectedClip?.kind.isCamera == true {
                inspectorTab = .picture
                pictureTab = .camera
            }
        }
        .onDisappear { fullScreen.close() }
    }

    private func handleKey(_ event: NSEvent, _ window: NSWindow) -> Bool {
        guard !editor.isBusy, !showingAgentEditing, (window.firstResponder as? NSTextView)?.isEditable != true,
              let action = shortcuts.action(for: event) else { return false }
        if event.isARepeat { return true }
        switch action {
        case .playback: togglePlayback()
        case .save: editor.saveProject()
        case .splitTrack, .splitAll:
            let allTracks = action == .splitAll
            if editor.canSplit(allTracks: allTracks) { editor.split(allTracks: allTracks) }
        case .deleteClip:
            if editor.selectedSubtitleID != nil { editor.deleteSubtitle() }
            else { editor.deleteClip(closeGap: false) }
        case .undo: editor.undoClips()
        default: return false
        }
        return true
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Button(action: leave) { Label("返回录制", systemImage: "chevron.left") }
            VStack(alignment: .leading, spacing: 1) {
                Text("剪辑工作台").font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(editor.manifest.timelineClips.count) 个素材片段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 2)
            Spacer(minLength: 8)
            if let url = editor.lastExport {
                Button("播放成片") { NSWorkspace.shared.open(url) }
            }
            Button(action: continueRecording) { Label("继续录制", systemImage: "record.circle") }
            Button("保存工程…") { editor.saveProject() }
                .help("保存工程 \(shortcuts[.save].label)")
            Button {
                showingAgentEditing.toggle()
            } label: {
                Label("Agent 剪辑", systemImage: "sparkles")
            }
            .help("生成 Agent 素材包或导入剪辑方案")
            .popover(isPresented: $showingAgentEditing) {
                AgentEditingPanel(canCreateBundle: editor.canMakeAgentBundle, lastBundle: editor.lastAgentBundle,
                                  createBundle: { runAgentAction(editor.makeAgentBundle) },
                                  importPlan: { runAgentAction(editor.importAgentPlan) })
            }
            Menu {
                Button("追加 MP4…") { editor.importMovie() }
                Divider()
                SettingsLink { Label("快捷键设置", systemImage: "keyboard") }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            Button {
                inspectorVisible.toggle()
                if !inspectorVisible { pickingFocus = false }
            } label: {
                Label("设置", systemImage: "sidebar.right")
            }
            .help(inspectorVisible ? "收起编辑设置" : "展开编辑设置")
            .accessibilityLabel(inspectorVisible ? "收起编辑设置" : "展开编辑设置")
            Button { editor.export() } label: {
                Label("导出 MP4…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(DeskPrimaryButton(color: WorkbenchStyle.action))
            TakeRecAboutButton()
        }
        .controlSize(.small)
    }

    private func runAgentAction(_ action: @escaping @MainActor () -> Void) {
        showingAgentEditing = false
        Task { @MainActor in action() }
    }

    private func timelineDivider(height: CGFloat, limits: ClosedRange<CGFloat>) -> some View {
        Capsule().fill(Color.secondary.opacity(0.40))
            .frame(width: 38, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .help("上下拖动调整预览高度，双击恢复默认")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($dividerTranslation) { value, translation, _ in
                    translation = value.translation.height
                }
                .onEnded { value in
                    timelineHeight = clamp(height - value.translation.height, limits.lowerBound, limits.upperBound)
                })
            .onTapGesture(count: 2) { timelineHeight = nil }
            .accessibilityLabel("预览和时间线之间的分隔柄")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: timelineHeight = min(limits.upperBound, height + 24)
                case .decrement: timelineHeight = max(limits.lowerBound, height - 24)
                @unknown default: break
                }
            }
    }

    private var viewer: some View {
        GeometryReader { geometry in
            let controlsHeight: CGFloat = 34
            let available = CGSize(width: max(0, geometry.size.width - 16),
                                   height: max(0, geometry.size.height - controlsHeight - 14))
            let imageSize = PreviewGeometry.fit(editor.previewSize, in: available)
            let controlsWidth = min(available.width, max(imageSize.width, 380))
            VStack(spacing: 5) {
                preview(size: imageSize)
                playbackControls
                    .frame(width: controlsWidth, height: controlsHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("成片预览").font(.callout.weight(.semibold))
                if editor.previewReady {
                    Text("\(Int(editor.previewSize.width)) × \(Int(editor.previewSize.height))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            Menu {
                ForEach(OutputFraming.allCases) { framing in
                    Button {
                        editor.canvas.framing = framing
                        if framing == .portrait {
                            inspectorVisible = true
                            inspectorTab = .picture
                            pictureTab = .layout
                            layoutTab = .background
                            pickingFocus = false
                        }
                    } label: {
                        if editor.canvas.framing == framing { Label(framing.title, systemImage: "checkmark") }
                        else { Text(framing.title) }
                    }
                }
            } label: {
                Text(editor.canvas.framing.title).lineLimit(1)
            }
            .fixedSize()
            .accessibilityLabel("成片比例")
            .help("切换成片画布比例")
            transport
            Button { fullScreen.show(editor: editor, shortcuts: shortcuts) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 16, height: 16)
            }
            .disabled(!editor.previewReady)
            .help("全屏预览")
            .accessibilityLabel("全屏预览")
        }
        .controlSize(.small)
    }

    private func preview(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            WorkbenchStyle.canvas
            if editor.previewReady && !fullScreen.isPresented {
                PlayerSurface(player: editor.player)
                    .frame(width: size.width, height: size.height)
            } else if !editor.previewReady {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if pickingFocus, size.width > 0, size.height > 0 {
                Color.orange.opacity(0.08)
                    .overlay(Rectangle().strokeBorder(.orange.opacity(0.75), lineWidth: 1))
                    .gesture(SpatialTapGesture().onEnded { tap in
                        editor.addFocus(at: CGPoint(x: tap.location.x / size.width, y: tap.location.y / size.height))
                        pickingFocus = false
                    })

                Text("点击画面设置焦点").font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            } else if editor.previewReady && !fullScreen.isPresented {
                Button {
                    fullScreen.show(editor: editor, shortcuts: shortcuts)
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("点击画面全屏预览").accessibilityLabel("全屏预览")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(WorkbenchStyle.line).allowsHitTesting(false)
        }
        .accessibilityLabel("成片预览")
    }

    private var transport: some View {
        PreviewTransport(editor: editor, playbackKey: shortcuts[.playback].label, togglePlayback: togglePlayback)
    }

    private func togglePlayback() {
        guard editor.previewReady else { return }
        pickingFocus = false
        editor.togglePlayback()
    }

    private var focusControls: some View {
        HStack(spacing: 7) {
            Button { editor.jumpFocus(next: false) } label: { Image(systemName: "chevron.left") }
                .help("上一个点击").accessibilityLabel("上一个点击")
            Button { editor.jumpFocus(next: true) } label: { Image(systemName: "chevron.right") }
                .help("下一个点击").accessibilityLabel("下一个点击")
            Button(pickingFocus ? "取消点选" : "添加焦点") {
                editor.seek(to: editor.playhead)
                pickingFocus.toggle()
            }
            .disabled(!editor.previewReady || !editor.manifest.timelineClips.contains {
                $0.kind == .screen && $0.contains(editor.playhead)
            })
            Button("移除焦点") { editor.removeFocus() }.disabled(editor.nearestFocus() == nil)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑设置").font(.headline)
                Spacer()
                Button {
                    inspectorVisible = false
                    pickingFocus = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起设置")
                .accessibilityLabel("收起设置")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            HStack(spacing: 3) {
                ForEach(InspectorTab.allCases) { tab in
                    let selected = inspectorTab == tab
                    Button {
                        inspectorTab = tab
                        if tab != .motion { pickingFocus = false }
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.callout.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? WorkbenchStyle.accent : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 27)
                            .background(selected ? WorkbenchStyle.accent.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
            ViewThatFits(in: .vertical) {
                inspectorControls.fixedSize(horizontal: false, vertical: true)
                ScrollView { inspectorControls }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var inspectorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch inspectorTab {
            case .picture:
                Picker("画面设置", selection: $pictureTab) {
                    ForEach(PictureTab.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch pictureTab {
                case .clip: trackInspector
                case .camera: cameraInspector
                case .keyboard: keyboardInspector
                case .layout: CanvasInspector(editor: editor, tab: $layoutTab)
                }
            case .motion:
                Picker("运镜设置", selection: $motionTab) {
                    ForEach(MotionTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch motionTab {
                case .zoom: motionInspector
                case .cursor: cursorInspector
                case .click: clickInspector
                }
            case .audio: audioInspector
            case .captions: SubtitleInspector(editor: editor, showingTranscriptionTools: $showingTranscriptionTools)
            }
        }
        .controlSize(.small)
        .padding(12)
    }

    private func showSubtitles() {
        pickingFocus = false
        inspectorVisible = true
        inspectorTab = .captions
    }

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label { Text(title).font(.subheadline.weight(.semibold)) } icon: { DeskIcon(icon) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackInspector: some View {
        let kind = editor.selectedTrack
        return section(editor.manifest.trackTitle(kind) + "轨", icon: kind.icon) {
            if let clip = editor.selectedClip {
                Text(clip.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("位置 \(timelineTime(clip.at)) · 时长 \(timelineTime(clip.length))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Button("左端到播放头") { trim(clip, left: true) }
                    Button("右端到播放头") { trim(clip, left: false) }
                }
                .controlSize(.small)
            } else {
                Text("拖片段移动，拖两端裁切。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(kind.isVideo ? "显示此轨" : "播放此轨", isOn: Binding(
                get: { editor.manifest.edit(kind).enabled },
                set: { editor.setTrackEnabled(kind, $0) }
            ))
            if !kind.isVideo { audioVolume(kind, title: "音量") }
        }
    }

    private var cameraInspector: some View {
        let angles = editor.manifest.cameraTracks
        let selection = angles.contains(editor.selectedTrack) ? editor.selectedTrack : angles.first
        return section(angles.count > 1 ? "人像机位" : "人像", icon: "video") {
            if let kind = selection {
                if angles.count > 1 {
                    Picker("机位", selection: Binding(get: { kind }, set: editor.selectTrack)) {
                        ForEach(angles) { Text(editor.manifest.trackDescription($0)).tag($0) }
                    }
                    Toggle("显示此机位", isOn: Binding(
                        get: { editor.manifest.edit(kind).enabled }, set: { editor.setTrackEnabled(kind, $0) }
                    ))
                    Button("从播放头切到此机位") { editor.switchCamera(to: kind) }
                        .disabled(!editor.canSwitchCamera(to: kind))
                        .help("从播放头到此机位片段结束，只显示这一机位。可撤销。")
                }
                if let clip = editor.selectedClip, clip.kind == kind {
                    Toggle("显示所选片段", isOn: Binding(
                        get: { clip.hidden != true }, set: { editor.setCameraClipVisible(clip, $0) }
                    ))
                    .disabled(!editor.manifest.edit(kind).enabled)
                }
                Toggle(angles.count > 1 ? "镜像此机位" : "镜像人像", isOn: Binding(
                    get: { editor.manifest.cameraMirrored(kind) }, set: { editor.setCameraMirror(kind, $0) }
                ))
                if editor.canvas.framing == .portrait {
                    Button("调整竖屏人像布局…") {
                        layoutTab = .camera
                        pictureTab = .layout
                    }
                } else {
                    Picker("形状", selection: Binding(get: { editor.manifest.effects.cameraShape },
                                                        set: { editor.manifest.effects.personShape = $0 })) {
                        ForEach(CameraShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker(angles.count > 1 ? "并排位置" : "位置", selection: $editor.manifest.effects.cameraCorner) {
                        ForEach(CameraCorner.allCases) { Text($0.rawValue).tag($0) }
                    }
                    adjust("人像尺寸", value: $editor.manifest.effects.cameraSize, range: 0.12...0.55,
                           text: percent(editor.manifest.effects.cameraSize))
                }
                Button("人像调光…") { showLighting.toggle() }
                    .popover(isPresented: $showLighting, arrowEdge: .bottom) {
                        PortraitLightingControls(lighting: Binding(
                            get: { editor.manifest.effects.portraitLighting ?? PortraitLighting() },
                            set: { editor.manifest.effects.portraitLighting = $0 == PortraitLighting() ? nil : $0 }
                        ))
                        .padding(14).frame(width: 280)
                    }
            } else {
                Text("录制时开启摄像头，即可编辑独立人像。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var keyboardInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.manifest.hasKeyboardTrack {
                Toggle("显示按键轨", isOn: $editor.keyboardVisible)
                Picker("位置", selection: $editor.manifest.effects.keyboardCorner) {
                    Text("沿用录制位置").tag(nil as CameraCorner?)
                    ForEach(CameraCorner.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .disabled(editor.manifest.effects.showKeyboard == false)
                if !editor.manifest.hasKeyboardPresses {
                    Text("当前片段没有收到按键。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("这段素材没有按键记录。录制前开启「保留按键轨」，剪辑时即可选择显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trim(_ clip: TimelineClip, left: Bool) {
        editor.editClip(ClipEdit.trimmed(clip, left: left, to: editor.playhead,
                                         among: editor.manifest.timelineClips, playhead: editor.playhead, snap: 0))
    }

    private var motionInspector: some View {
        let effect = editor.manifest.effects
        return section("点击运镜", icon: "mouse-pointer-2") {
            Toggle("点击自动运镜", isOn: $editor.manifest.effects.autoZoom)
            Toggle("放大时跟随光标", isOn: $editor.manifest.effects.followPointer)
            adjust("放大倍率", value: $editor.manifest.effects.zoom, range: 1...3, text: String(format: "%.2f×", effect.zoom))
            focusControls
            Button("过渡与停留…") { showMotionTiming.toggle() }
                .popover(isPresented: $showMotionTiming, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        adjust("过渡用时", value: $editor.manifest.effects.transition, range: 0.12...1.2,
                               text: String(format: "%.2f s", editor.manifest.effects.transition))
                        adjust("放大停留", value: $editor.manifest.effects.hold, range: 0.15...3,
                               text: String(format: "%.2f s", editor.manifest.effects.hold))
                        adjust("过渡虚化", value: $editor.manifest.effects.blur, range: 0...10,
                               text: String(format: "%.1f", editor.manifest.effects.blur))
                    }
                    .padding(14).frame(width: 290)
                }
        }
    }

    private var cursorInspector: some View {
        let effect = editor.manifest.effects
        return section("光标样式", icon: "mouse-pointer-2") {
            if editor.manifest.drawsEditableCursor {
                cursorPicker
                adjust("光标大小", value: $editor.manifest.effects.cursorSize, range: 0.5...3, text: percent(effect.cursorSize))
                adjust("移动缓动", value: $editor.manifest.effects.smoothing, range: 0...0.35, text: String(format: "%.2f s", effect.smoothing))
                Toggle("光标轨迹尾迹", isOn: $editor.manifest.effects.cursorTrail)
            } else {
                Text("光标随原片画面保留。点击波纹和运镜仍可单独编辑。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var clickInspector: some View {
        let effect = editor.manifest.effects
        return section("点击效果", icon: "audio-lines") {
            Toggle("点击波纹", isOn: $editor.manifest.effects.ripple)
            Toggle("点击音效", isOn: $editor.manifest.effects.clickSound)
            if effect.clickSound {
                HStack {
                    Picker("声音", selection: Binding(get: { editor.manifest.effects.clickPreset },
                                                        set: { editor.manifest.effects.soundChoice = $0 })) {
                        ForEach(ClickSound.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button { editor.auditionClick() } label: { DeskIcon("play", size: 13) }
                        .help("试听点击音效").accessibilityLabel("试听点击音效")
                }
                adjust("音效音量", value: $editor.manifest.effects.clickVolume, range: 0...1, text: percent(effect.clickVolume))
            }
        }
    }

    private var audioInspector: some View {
        let tracks = editor.manifest.tracks.filter { !$0.isVideo }
        return section("音量与人声", icon: "audio-lines") {
            if tracks.isEmpty {
                Text("录制麦克风或系统声音后，可在这里调整音量。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(tracks) { kind in
                audioVolume(kind, title: kind.title)
                if kind == .microphone {
                    HStack(spacing: 6) {
                        Text("增强").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ForEach([1.0, 1.5, 2.0], id: \.self) { gain in
                            Button(percent(gain)) { editor.setTrackVolume(.microphone, gain) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if editor.manifest.hasNarrationTracks {
                Divider()
                Toggle("说话时自动压低原声", isOn: Binding(
                    get: { editor.manifest.duckSystemAudio == true },
                    set: { editor.manifest.duckSystemAudio = $0 }
                ))
                Button("应用人声优先配比") { editor.manifest.applyNarrationMix() }
                    .help("将麦克风设为至少 100%，原声降到 30% 或更低，并开启自动压低")
            }
        }
    }

    private func audioVolume(_ kind: TrackKind, title: String) -> some View {
        let volume = Binding(get: { editor.manifest.edit(kind).volume }, set: { editor.setTrackVolume(kind, $0) })
        return adjust(title, value: volume, range: 0...kind.maximumVolume, text: percent(volume.wrappedValue))
    }

    private var cursorPicker: some View {
        HStack(spacing: 7) {
            Text("光标样式")
            Spacer()
            Button {
                showCursorMenu.toggle()
            } label: {
                HStack {
                    CursorSample(style: editor.manifest.effects.cursor)
                    Text(editor.manifest.effects.cursor.rawValue)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .popover(isPresented: $showCursorMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CursorStyle.allCases) { style in
                        Button {
                            editor.manifest.effects.cursor = style
                            showCursorMenu = false
                        } label: {
                            HStack(spacing: 8) {
                                CursorSample(style: style)
                                Text(style.rawValue)
                                Spacer()
                                if editor.manifest.effects.cursor == style {
                                    Image(systemName: "checkmark").font(.caption)
                                }
                            }
                            .padding(5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(width: 160)
            }
        }
    }

    private func adjust(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 57, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small).accessibilityLabel(name)
            Text(text).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.caption)
    }

    private func percent(_ value: Double) -> String { "\(Int(clamp(value * 100, 0, 10_000).rounded()))%" }
}

private struct CursorSample: View {
    let style: CursorStyle

    private static let images: [CursorStyle: CGImage] = {
        let context = CIContext()
        return Dictionary(uniqueKeysWithValues: CursorStyle.allCases.compactMap { style in
            guard let glyph = TakeCompositor.glyph(style)?.0,
                  let image = context.createCGImage(glyph, from: glyph.extent) else { return nil }
            return (style, image)
        })
    }()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.55, green: 0.60, blue: 0.65))
            if let image = Self.images[style] {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(.white)
            }
        }
        .frame(width: 23, height: 22)
        .accessibilityHidden(true)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
