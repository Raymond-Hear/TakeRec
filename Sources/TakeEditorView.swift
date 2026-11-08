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
    @State private var inspectorTab = InspectorTab.clip
    @StateObject private var fullScreen = FullScreenPreview()

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case clip = "片段", camera = "人像", motion = "运镜", cursor = "光标", click = "点击", audio = "声音"
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            let inspectorWidth = min(355, max(298, geometry.size.width * 0.30))
            let timelineHeight = min(335, geometry.size.height * 0.40)

            VStack(alignment: .leading, spacing: 11) {
                toolbar
                HStack(alignment: .top, spacing: 15) {
                    viewer
                        .frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity)
                    inspector
                        .frame(width: inspectorWidth)
                }
                .frame(maxHeight: .infinity)
                ClipTimelineView(editor: editor, shortcuts: shortcuts, maximumLaneHeight: timelineHeight)
                if let notice = editor.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 665)
        .disabled(editor.isBusy)
        .background(ShortcutEventMonitor(handle: handleKey))
        .onDisappear { fullScreen.close() }
    }

    private func handleKey(_ event: NSEvent, _ window: NSWindow) -> Bool {
        guard !editor.isBusy, (window.firstResponder as? NSTextView)?.isEditable != true,
              let action = shortcuts.action(for: event) else { return false }
        if event.isARepeat { return true }
        switch action {
        case .playback: togglePlayback()
        case .save: editor.saveProject()
        case .splitTrack, .splitAll:
            let allTracks = action == .splitAll
            if editor.canSplit(allTracks: allTracks) { editor.split(allTracks: allTracks) }
        case .deleteClip: editor.deleteClip(closeGap: false)
        case .undo: editor.undoClips()
        default: return false
        }
        return true
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: leave) { Label("返回录制", systemImage: "chevron.left") }
            VStack(alignment: .leading, spacing: 1) {
                Text("录制编辑").font(.headline)
                Text("\(editor.manifest.tracks.count) 条轨道 · \(editor.manifest.timelineClips.count) 个片段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let activity = editor.activity {
                ProgressView().controlSize(.small)
                Text(activity).font(.callout)
            }
            if let url = editor.lastExport {
                Button("播放成片") { NSWorkspace.shared.open(url) }
            }
            Button(action: continueRecording) { Label("继续录制", systemImage: "record.circle") }
            Button {
                editor.importMovie()
            } label: {
                Label { Text("追加 MP4…") } icon: { DeskIcon("plus", size: 14) }
            }
            Menu("Agent 剪辑") {
                Button("生成素材包并复制提示词…") { editor.makeAgentBundle() }
                Button("导入剪辑方案…") { editor.importAgentPlan() }
            }
            .fixedSize()
            Button("保存工程…") { editor.saveProject() }
                .help("保存工程 \(shortcuts[.save].label)")
            Button("导出 MP4…") { editor.export() }.buttonStyle(DeskPrimaryButton())
            SettingsLink {
                Label("快捷键设置", systemImage: "keyboard").labelStyle(.iconOnly)
            }
            .help("快捷键设置")
        }
    }

    private var viewer: some View {
        GeometryReader { geometry in
            let transportHeight: CGFloat = 30
            let gap: CGFloat = 7
            let available = CGSize(width: geometry.size.width,
                                   height: max(0, geometry.size.height - transportHeight - gap))
            let imageSize = PreviewGeometry.fit(editor.previewSize, in: available)
            let transportWidth = max(imageSize.width, min(350, geometry.size.width))

            VStack(spacing: gap) {
                preview(size: imageSize)
                transport
                    .frame(width: transportWidth, height: transportHeight)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .frame(minHeight: 226)
    }

    private func preview(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            Color.secondary.opacity(0.09)
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
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                }
                .buttonStyle(.plain).help("点击画面全屏预览").accessibilityLabel("全屏预览")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 8) {
            Picker("编辑设置", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch inspectorTab {
            case .clip: trackInspector
            case .camera: cameraInspector
            case .motion: motionInspector
            case .cursor: cursorInspector
            case .click: clickInspector
            case .audio: audioInspector
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label { Text(title).font(.subheadline.weight(.semibold)) } icon: { DeskIcon(icon) }
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trackInspector: some View {
        let kind = editor.selectedTrack
        return section(kind.title + "轨", icon: kind.icon) {
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
        section("人像", icon: "video") {
            if editor.manifest.tracks.contains(.camera) {
                Toggle("镜像人像", isOn: Binding(get: { editor.manifest.effects.cameraMirrored },
                                                  set: { editor.manifest.effects.personMirrored = $0 }))
                Picker("形状", selection: Binding(get: { editor.manifest.effects.cameraShape },
                                                    set: { editor.manifest.effects.personShape = $0 })) {
                    ForEach(CameraShape.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("位置", selection: $editor.manifest.effects.cameraCorner) {
                    ForEach(CameraCorner.allCases) { Text($0.rawValue).tag($0) }
                }
                adjust("人像尺寸", value: $editor.manifest.effects.cameraSize, range: 0.12...0.55,
                       text: percent(editor.manifest.effects.cameraSize))
                Divider()
                PortraitLightingControls(lighting: Binding(
                    get: { editor.manifest.effects.portraitLighting ?? PortraitLighting() },
                    set: { editor.manifest.effects.portraitLighting = $0 == PortraitLighting() ? nil : $0 }
                ))
            } else {
                Text("录制时开启摄像头，即可编辑独立人像。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
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
            adjust("过渡用时", value: $editor.manifest.effects.transition, range: 0.12...1.2, text: String(format: "%.2f s", effect.transition))
            adjust("放大停留", value: $editor.manifest.effects.hold, range: 0.15...3, text: String(format: "%.2f s", effect.hold))
            adjust("过渡虚化", value: $editor.manifest.effects.blur, range: 0...10, text: String(format: "%.1f", effect.blur))
            Divider()
            focusControls
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
