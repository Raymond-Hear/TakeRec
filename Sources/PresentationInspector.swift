import SwiftUI

struct CanvasInspector: View {
    @ObservedObject var editor: TakeEditorModel
    @Binding var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case background = "底板", screen = "录屏", camera = "人像"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("成片比例", selection: $editor.canvas.framing) {
                ForEach(OutputFraming.allCases) { Text($0.title).tag($0) }
            }
            if editor.canvas.framing == .portrait {
                Picker("竖屏分区", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case .background: backgroundControls
                case .screen:
                    placementControls(\.screen, aspect: editor.sourceAspect)
                case .camera:
                    Picker("人像形状", selection: $editor.canvas.portrait.cameraShape) {
                        Text("圆形").tag(CameraShape.circle)
                        Text("圆角矩形").tag(CameraShape.rounded)
                    }
                    placementControls(\.camera, aspect: editor.canvas.portrait.cameraAspect)
                    if editor.manifest.cameraTracks.isEmpty {
                        Text("有独立人像轨时，这里会显示人像。").font(.caption).foregroundStyle(.secondary)
                    } else if editor.manifest.cameraTracks.count > 1 {
                        Text("同时显示的机位会并排放置，空间不足时自动缩小。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var backgroundControls: some View {
        let size = editor.canvas.portrait.dimensions
        return VStack(alignment: .leading, spacing: 8) {
            Picker("背景", selection: $editor.canvas.portrait.background) {
                ForEach(CanvasBackground.allCases.filter { $0 != .image || editor.canvas.portrait.backgroundAsset != nil }) {
                    Text($0.title).tag($0)
                }
            }
            HStack(spacing: 6) {
                Button("导入图片…") { editor.importCanvasBackground() }
                Button("导出底板 PNG…") { editor.exportCanvasBackground() }
            }
            HStack {
                Text("成片尺寸").font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(size.width)) × \(Int(size.height)) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(editor.canvas.portrait.dimensions.width) },
                set: { editor.canvas.portrait.pixelWidth = Int($0.rounded()) }
            ), in: 540...2160, step: 18)
            .accessibilityLabel("竖屏成片宽度")
            Toggle("显示中部播放进度条", isOn: $editor.canvas.portrait.showsProgress)
                .toggleStyle(.checkbox)
        }
    }

    private func placementControls(_ key: WritableKeyPath<PortraitCanvas, CanvasPlacement>, aspect: CGFloat) -> some View {
        let canvas = CGRect(origin: .zero, size: editor.canvas.portrait.dimensions)
        let placement = editor.canvas.portrait[keyPath: key]
        let box = placement.bounds(in: canvas, aspect: aspect)
        let maxWidth = min(canvas.width, canvas.height * aspect)
        let minWidth = min(maxWidth, canvas.width * 0.06)
        return VStack(alignment: .leading, spacing: 8) {
            pixelSlider("宽度", value: box.width, range: minWidth...maxWidth) {
                editor.canvas.portrait[keyPath: key].width = $0 / canvas.width
            }
            pixelSlider("水平中心", value: box.midX, range: (box.width / 2)...(canvas.width - box.width / 2)) {
                editor.canvas.portrait[keyPath: key].x = $0 / canvas.width
            }
            pixelSlider("垂直中心", value: canvas.height - box.midY,
                        range: (box.height / 2)...max(box.height / 2, canvas.height - box.height / 2)) {
                editor.canvas.portrait[keyPath: key].y = $0 / canvas.height
            }
            Text("坐标从画布左上角量起。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pixelSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                             set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 7) {
            Text(label).frame(width: 52, alignment: .leading)
            if range.upperBound - range.lowerBound > 1 {
                Slider(value: Binding(get: { value }, set: { set(clamp($0.rounded(), range.lowerBound, range.upperBound)) }),
                       in: range).accessibilityLabel(label)
            } else {
                Spacer(minLength: 0)
            }
            Text("\(Int(value.rounded())) px").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .font(.caption)
    }
}

struct SubtitleInspector: View {
    @ObservedObject var editor: TakeEditorModel
    @Binding var showingTranscriptionTools: Bool
    @State private var showsStyle = false
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    private static let tingwuURL = URL(string: "https://tingwu.aliyun.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("导入 SRT / TXT…") { editor.importSubtitles() }
                Button("添加字幕") { editor.addSubtitle() }
            }
            Button {
                showingTranscriptionTools.toggle()
            } label: {
                HStack {
                    Label("临时导出", systemImage: "waveform.badge.arrow.up")
                    Spacer()
                    Image(systemName: showingTranscriptionTools ? "chevron.up" : "chevron.down")
                        .imageScale(.small).accessibilityHidden(true)
                }
            }
            .accessibilityValue(showingTranscriptionTools ? "已展开" : "已收起")
            if showingTranscriptionTools { transcriptionTools }
            if let activity = editor.subtitleActivity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if let notice = editor.subtitleNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            DisclosureGroup("字幕样式", isExpanded: $showsStyle) { styleControls.padding(.top, 5) }
            if !editor.manifest.subtitleCues.isEmpty {
                subtitleList
            } else {
                Text("导入听悟的字幕，或在播放头位置添加一条。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let cue = editor.selectedSubtitle { editControls(cue).id(cue.id) }
        }
    }

    private var transcriptionTools: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("导出当前剪辑用于转写。只需要声音时，可以选体积更小的 M4A。")
            HStack(spacing: 6) {
                Button("音频 M4A…") { editor.quickExport(audioOnly: true) }
                Button("低清 MP4…") { editor.quickExport(audioOnly: false) }
            }
            .disabled(!editor.canMakeAgentBundle)
            if let file = editor.lastQuickExport {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已导出 · \(file.lastPathComponent)").lineLimit(2).textSelection(.enabled)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.link)
                }
            }
            Divider()
            Link(destination: Self.tingwuURL) {
                Label("打开通义听悟", systemImage: "arrow.up.right.square")
            }
            .help("在浏览器打开通义听悟")
            Text("在听悟选择「上传音视频」，选中刚导出的文件。转写完成后下载 SRT，回到这里点「导入 SRT / TXT…」。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("字体", selection: $editor.captionStyle.fontFamily) {
                Text("系统默认").tag("")
                let current = editor.captionStyle.fontFamily
                if !current.isEmpty, !Self.fontFamilies.contains(current) { Text(current).tag(current) }
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Toggle("加粗", isOn: $editor.captionStyle.bold).toggleStyle(.checkbox)
            HStack {
                Slider(value: $editor.captionStyle.size, in: 20...104, step: 1) { Text("字号") }
                Text("\(Int(editor.captionStyle.size))").monospacedDigit().frame(width: 35, alignment: .trailing)
            }
            HStack {
                Slider(value: $editor.captionStyle.backdrop, in: 0...1) { Text("底色") }
                Text("\(Int((editor.captionStyle.backdrop * 100).rounded()))%").monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
            }
        }
    }

    private var subtitleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("字幕列表 · \(editor.manifest.subtitleCues.count) 条")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(editor.manifest.subtitleCues) { cue in
                            Button { editor.selectSubtitle(cue) } label: {
                                HStack(spacing: 6) {
                                    Text(timelineTime(cue.start)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(cue.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption)
                                .padding(.horizontal, 5).frame(height: 22)
                                .background(cue.id == editor.selectedSubtitleID ? WorkbenchStyle.accent.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(cue.id == editor.selectedSubtitleID ? .isSelected : [])
                            .id(cue.id)
                        }
                    }
                }
                .frame(height: min(88, CGFloat(editor.manifest.subtitleCues.count) * 23))
                .onChange(of: editor.selectedSubtitleID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func editControls(_ cue: SubtitleCue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: Binding(
                get: { editor.selectedSubtitle?.text ?? cue.text },
                set: { text in
                    guard var current = editor.selectedSubtitle, current.id == cue.id else { return }
                    current.text = text
                    editor.updateSubtitle(current, record: false)
                }
            ))
            .font(.callout)
            .frame(height: 57)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(WorkbenchStyle.line).allowsHitTesting(false) }
            .accessibilityLabel("字幕文字")
            HStack(spacing: 6) {
                timingField("起始秒", cue: cue, start: true)
                timingField("结束秒", cue: cue, start: false)
                Button(role: .destructive) { editor.deleteSubtitle() } label: { Image(systemName: "trash") }
                    .help("删除所选字幕").accessibilityLabel("删除所选字幕")
            }
        }
    }

    private func timingField(_ label: String, cue: SubtitleCue, start: Bool) -> some View {
        let value = Binding(
            get: { start ? cue.start : cue.end },
            set: { seconds in
                guard seconds.isFinite, let current = editor.selectedSubtitle, current.id == cue.id else { return }
                let duration = editor.manifest.timelineDuration
                guard duration >= SubtitleCue.minimumDuration - 0.00001 else { return }
                let minimum = min(SubtitleCue.minimumDuration, current.end - current.start)
                let lower = start ? clamp(seconds, 0, max(0, min(current.end, duration) - minimum)) : current.start
                let upper = start ? current.end : clamp(seconds, lower + minimum, duration)
                guard upper > lower else { return }
                var next = current
                next.start = lower
                next.end = upper
                editor.updateSubtitle(next)
                editor.seek(to: next.start)
            }
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().monospacedDigit().textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }
}
