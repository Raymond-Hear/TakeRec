import SwiftUI

struct ClipTimelineView: View {
    @ObservedObject var editor: TakeEditorModel
    @ObservedObject var shortcuts: ShortcutPreferences
    let maximumLaneHeight: CGFloat
    @Binding var tall: Bool
    @Binding var autoCloseGaps: Bool
    let showSubtitles: () -> Void
    let showTitles: () -> Void
    @State private var zoom = 0.0
    @State private var horizontalStart = 0.0
    @State private var thumbnails: [TimelineThumbnail: CGImage] = [:]
    @State private var snap = true
    private let headerWidth: CGFloat = 114
    private static let rulerHeight: CGFloat = 24
    private static let markerHeight: CGFloat = 18
    private static let keyboardHeight: CGFloat = 30
    private static let subtitleHeight: CGFloat = 34
    private static let laneSpacing: CGFloat = 2
    private static let bottomInset: CGFloat = 5
    private let inset: CGFloat = 8
    private let columnGap: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let viewport = timelineViewport(width: geometry.size.width - inset * 2 - headerWidth - columnGap)
            let requests = thumbnailRequests(in: viewport)
            VStack(alignment: .leading, spacing: 0) {
                toolbar(viewport)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: columnGap) {
                        headers
                        VStack(spacing: Self.laneSpacing) {
                            ruler(viewport)
                            markerLane(viewport)
                            if !editor.manifest.titleCues.isEmpty { titleLane(viewport) }
                            subtitleLane(viewport)
                            if editor.manifest.hasKeyboardTrack { keyboardLane(viewport) }
                            ForEach(orderedTracks) { kind in
                                lane(kind: kind, in: viewport)
                            }
                        }
                        .overlay { playhead(viewport) }
                        .clipped()
                    }
                    .padding(.bottom, Self.bottomInset)
                }
                .scrollIndicators(lanesContentHeight > maximumLaneHeight ? .visible : .hidden, axes: .vertical)
                .frame(height: laneViewportHeight)
                .padding(.horizontal, inset)
                .background(TimelineWheelMonitor { action, pointerX in
                    handleWheel(action, x: pointerX - inset - headerWidth - columnGap, width: viewport.width)
                })
                Rectangle().fill(WorkbenchStyle.line).frame(height: 1)
                horizontalNavigation(viewport)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
            }
            .task(id: requests) {
                guard !requests.isEmpty else { thumbnails = [:]; return }
                do {
                    try await Task.sleep(for: .milliseconds(70))
                    let frames = await editor.thumbnailCache.images(for: requests, in: editor.project)
                    try Task.checkCancellation()
                    thumbnails = frames
                } catch { }
            }
        }
        .frame(height: laneViewportHeight + 58)
        .workbenchPanel()
    }

    private func timelineViewport(width: Double) -> TimelineViewport {
        TimelineViewport(duration: editor.duration, width: width, zoom: zoom, start: horizontalStart)
    }

    private func thumbnailRequests(in viewport: TimelineViewport) -> [TimelineThumbnail] {
        let frames = editor.manifest.timelineClips.flatMap { clip in
            TimelineFilmstrip.cells(for: clip, in: viewport).map(\.thumbnail)
        }
        return Set(frames).sorted { ($0.file, $0.tick) < ($1.file, $1.tick) }
    }

    private func handleWheel(_ action: TimelineWheelAction, x: Double, width: Double) {
        let viewport = timelineViewport(width: width)
        switch action {
        case .zoom(let stops):
            let next = viewport.zoomed(by: stops, at: x)
            zoom = next.zoom
            horizontalStart = next.start
        case .pan(let points):
            horizontalStart = clamp(viewport.start + points / viewport.scale, 0, viewport.maximumStart)
        case .ignore: break
        }
    }

    private func horizontalNavigation(_ viewport: TimelineViewport) -> some View {
        HStack(spacing: 9) {
            Text("\(timelineTime(viewport.start)) – \(timelineTime(min(viewport.end, viewport.duration)))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Slider(value: Binding(
                get: { viewport.maximumStart > 0 ? viewport.start / viewport.maximumStart : 0 },
                set: { horizontalStart = $0 * viewport.maximumStart }
            ), in: 0...1)
            .disabled(viewport.maximumStart <= 0)
            .controlSize(.mini)
            .help("按住 Option（Alt）滚动滚轮可横移")
            .accessibilityLabel("横移时间线")
        }
    }

    private var laneViewportHeight: CGFloat {
        min(lanesContentHeight, maximumLaneHeight)
    }

    private var orderedTracks: [TrackKind] {
        editor.manifest.tracks.filter { $0 == .bRoll } + editor.manifest.tracks.filter { $0 != .bRoll }
    }

    private var lanesContentHeight: CGFloat {
        Self.laneContentHeight(trackCount: editor.manifest.tracks.count, tall: tall,
                               keyboard: editor.manifest.hasKeyboardTrack, titles: !editor.manifest.titleCues.isEmpty)
    }

    static func laneContentHeight(trackCount: Int, tall: Bool, keyboard: Bool = false, titles: Bool = false) -> CGFloat {
        let keys = keyboard ? keyboardHeight + laneSpacing : 0
        let title = titles ? subtitleHeight + laneSpacing : 0
        return rowHeight(tall: tall) * CGFloat(trackCount) + rulerHeight + markerHeight + subtitleHeight + keys + title
            + laneSpacing * CGFloat(trackCount + 2) + bottomInset
    }

    private static func rowHeight(tall: Bool) -> CGFloat { tall ? 76 : 43 }

    private func toolbar(_ viewport: TimelineViewport) -> some View {
        HStack(spacing: 8) {
            Text("时间线").font(.headline)
            Menu {
                Button("添加 B-roll 视频…") { editor.importBRoll() }.disabled(!editor.canMakeAgentBundle)
                Button("在播放头添加花字") { editor.addTitle(); showTitles() }
                    .disabled(editor.manifest.timelineDuration < SubtitleCue.minimumDuration)
            } label: {
                Label("添加", systemImage: "plus")
            }
            .fixedSize()
            Divider().frame(height: 15).padding(.horizontal, 2)
            Button {
                editor.split(allTracks: false)
            } label: {
                Label { Text("分割") } icon: { DeskIcon("scissors", size: 13) }
            }
            .disabled(!editor.canSplit(allTracks: false))
            .help("在播放头处分割当前轨道 \(shortcuts[.splitTrack].label)")
            Menu {
                Button("分割所有轨道  \(shortcuts[.splitAll].label)") { editor.split(allTracks: true) }
                    .disabled(!editor.canSplit(allTracks: true))
                Button("拼接当前轨的片段") { editor.packTrack() }
                    .disabled(!editor.manifest.timelineClips.contains { $0.kind == editor.selectedTrack })
                Divider()
                Button("删除所选  \(shortcuts[.deleteClip].label)") {
                    editor.deleteSelection(closeGap: autoCloseGaps && editor.selectionCanCloseGap)
                }
                .disabled(!editor.hasDeletableSelection)
                Button(autoCloseGaps ? "仅删除所选，保留空隙" : "删除所选时段并合拢所有轨道") {
                    editor.deleteSelection(closeGap: !autoCloseGaps)
                }
                .disabled(!editor.hasDeletableSelection || !editor.selectionCanCloseGap)
            } label: {
                Label("片段", systemImage: "link")
            }
            .fixedSize()
            Button {
                editor.undoClips()
            } label: {
                DeskIcon("undo-2", size: 14)
            }
            .help("撤销时间线操作 \(shortcuts[.undo].label)")
            .accessibilityLabel("撤销时间线操作")
            .disabled(!editor.hasUndo)
            Button {
                editor.redoClips()
            } label: {
                DeskIcon("redo-2", size: 14)
            }
            .help("重做时间线操作 \(shortcuts[.redo].label)")
            .accessibilityLabel("重做时间线操作")
            .disabled(!editor.hasRedo)
            Spacer(minLength: 4)
            Toggle("自动合拢", isOn: $autoCloseGaps).toggleStyle(.checkbox)
                .help("删除或缩短片段时，各轨一起前移。已有空隙可右键删除。")
            Toggle("拖动吸附", isOn: $snap).toggleStyle(.checkbox)
                .help("拖动或裁切时吸附到附近的时间点")
            Toggle("加高", isOn: $tall).toggleStyle(.checkbox)
            Divider().frame(height: 15).padding(.horizontal, 2)
            Button {
                zoom = 0
                horizontalStart = 0
            } label: {
                Image(systemName: "arrow.left.and.right")
            }
            .help("适合全片")
            .accessibilityLabel("适合全片")
            Slider(value: Binding(
                get: { zoom },
                set: { value in
                    let current = timelineViewport(width: viewport.width)
                    let playhead = current.x(at: editor.playhead)
                    let anchor = (0...current.width).contains(playhead) ? playhead : current.width / 2
                    let next = current.zoomed(to: value, at: anchor)
                    zoom = next.zoom
                    horizontalStart = next.start
                }
            ), in: TimelineViewport.zoomRange)
                .frame(width: 92)
                .help("按住 Ctrl 滚动滚轮可围绕指针位置缩放")
                .accessibilityLabel("时间线缩放")
        }
        .controlSize(.small)
    }

    private var headers: some View {
        VStack(spacing: Self.laneSpacing) {
            Text("轨道").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)
                .frame(width: headerWidth, height: Self.rulerHeight)
            Label { Text("点击标记") } icon: { DeskIcon("mouse-pointer-2", size: 14) }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)
                .frame(width: headerWidth, height: Self.markerHeight)
            if !editor.manifest.titleCues.isEmpty {
                Button(action: showTitles) { Label("花字轨", systemImage: "textformat") }
                    .buttonStyle(.plain).font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 7)
                    .frame(width: headerWidth, height: Self.subtitleHeight)
            }
            subtitleHeader
            if editor.manifest.hasKeyboardTrack { keyboardHeader }
            ForEach(orderedTracks) { kind in
                HStack(spacing: 4) {
                    Button {
                        editor.selectTrack(kind)
                    } label: {
                        HStack(spacing: 5) {
                            DeskIcon(kind.icon, size: 14).foregroundStyle(kind.color)
                            Text(editor.manifest.trackTitle(kind)).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(editor.selectedTrack == kind ? kind.color : .primary)
                    .help(editor.manifest.trackDescription(kind))
                    trackSwitch(kind)
                }
                .padding(.horizontal, 7)
                .frame(width: headerWidth, height: Self.rowHeight(tall: tall))
                .background(editor.selectedTrack == kind ? kind.color.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var subtitleHeader: some View {
        HStack(spacing: 4) {
            Button(action: showSubtitles) { Label("字幕轨", systemImage: "captions.bubble").lineLimit(1) }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .help("打开字幕编辑")
            Spacer(minLength: 0)
            let enabled = editor.captionStyle.enabled
            let action = enabled ? "隐藏字幕" : "显示字幕"
            Button { editor.captionStyle.enabled.toggle() } label: {
                Image(systemName: enabled ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 25, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(action).accessibilityLabel(action)
            .foregroundStyle(enabled ? Color.secondary : WorkbenchStyle.marker)
        }
        .padding(.horizontal, 7)
        .frame(width: headerWidth, height: Self.subtitleHeight)
    }

    private func subtitleLane(_ viewport: TimelineViewport) -> some View {
        let cues = editor.manifest.subtitleCues
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(WorkbenchStyle.lane)
                .frame(width: viewport.width, height: Self.subtitleHeight)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { editor.seek(to: viewport.time(at: $0.location.x)) })
            if cues.isEmpty {
                Button {
                    showSubtitles()
                    editor.importSubtitles()
                } label: {
                    Label("导入 SRT / TXT 字幕…", systemImage: "plus")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).padding(8)
            }
            ForEach(cues.filter { $0.end > viewport.start && $0.start < viewport.end }) { cue in
                TextCueTile(cue: cue, viewport: viewport, snapping: snap, height: Self.subtitleHeight,
                            duration: editor.manifest.timelineDuration, playhead: editor.playhead,
                            selected: editor.selectedSubtitleID == cue.id, enabled: editor.captionStyle.enabled,
                            color: WorkbenchStyle.accent,
                            select: { editor.selectSubtitle(cue, seek: $0); showSubtitles() },
                            update: { editor.updateSubtitle($0); editor.selectSubtitle($0) })
                    .zIndex(editor.selectedSubtitleID == cue.id ? 1 : 0)
            }
        }
        .frame(width: viewport.width, height: Self.subtitleHeight)
        .clipped()
    }

    private func titleLane(_ viewport: TimelineViewport) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(WorkbenchStyle.lane)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { editor.seek(to: viewport.time(at: $0.location.x)) })
            ForEach(editor.manifest.titleCues.filter { $0.end > viewport.start && $0.start < viewport.end }) { cue in
                TextCueTile(cue: cue, viewport: viewport, snapping: snap, height: Self.subtitleHeight,
                            duration: editor.manifest.timelineDuration, playhead: editor.playhead,
                            selected: editor.selectedTitleID == cue.id, enabled: true, color: WorkbenchStyle.marker,
                            select: { editor.selectTitle(cue, seek: $0); showTitles() },
                            update: { editor.updateTitle($0); editor.selectTitle($0) })
                    .zIndex(editor.selectedTitleID == cue.id ? 1 : 0)
            }
        }
        .frame(width: viewport.width, height: Self.subtitleHeight)
        .clipped()
    }

    private var keyboardHeader: some View {
        HStack(spacing: 4) {
            Label("按键轨", systemImage: "keyboard")
                .font(.callout.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            let action = editor.keyboardVisible ? "隐藏按键轨" : "显示按键轨"
            Button {
                editor.keyboardVisible.toggle()
            } label: {
                Image(systemName: editor.keyboardVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 25, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(action).accessibilityLabel(action)
            .foregroundStyle(editor.keyboardVisible ? Color.secondary : WorkbenchStyle.marker)
        }
        .padding(.horizontal, 7)
        .frame(width: headerWidth, height: Self.keyboardHeight)
    }

    private func keyboardLane(_ viewport: TimelineViewport) -> some View {
        let presses = editor.manifest.keyboardPresses(in: viewport.start..<viewport.end)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(WorkbenchStyle.lane)
            if !editor.manifest.hasKeyboardPresses {
                Text("这段没有按键记录").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
            }
            Canvas { context, size in
                var ticks = Path()
                var lastTick = -Double.infinity
                var lastLabel = -Double.infinity
                for press in presses {
                    let x = viewport.x(at: press.time)
                    guard x - lastTick >= 2 else { continue }
                    ticks.move(to: CGPoint(x: x, y: 6))
                    ticks.addLine(to: CGPoint(x: x, y: size.height - 6))
                    lastTick = x
                    if editor.keyboardVisible, x - lastLabel >= 56, x + 34 < size.width {
                        context.draw(Text(String(press.label.prefix(8))).font(.caption2.monospaced())
                            .foregroundStyle(WorkbenchStyle.accent), at: CGPoint(x: x + 4, y: size.height / 2),
                                     anchor: .leading)
                        lastLabel = x
                    }
                }
                context.stroke(ticks, with: .color(WorkbenchStyle.accent.opacity(editor.keyboardVisible ? 0.65 : 0.26)), lineWidth: 1.5)
            }
        }
        .frame(width: viewport.width, height: Self.keyboardHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { editor.seek(to: viewport.time(at: $0.location.x)) })
    }

    private func trackSwitch(_ kind: TrackKind) -> some View {
        let enabled = editor.manifest.edit(kind).enabled
        let icon = kind.isVideo ? (enabled ? "eye" : "eye.slash") : (enabled ? "speaker.wave.2" : "speaker.slash")
        let action = kind.isVideo ? (enabled ? "隐藏" : "显示") : (enabled ? "静音" : "取消静音")
        return Button {
            editor.setTrackEnabled(kind, !enabled)
        } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 25, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : WorkbenchStyle.marker)
        .help("\(action)\(kind.title)轨")
        .accessibilityLabel("\(action)\(kind.title)轨")
    }

    private func ruler(_ viewport: TimelineViewport) -> some View {
        let steps = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_800, 3_600.0]
        let target = 70 / viewport.scale
        let step = steps.first { $0 >= target } ?? target
        return Canvas { context, size in
            var ticks = Path()
            ticks.move(to: CGPoint(x: 0, y: size.height - 0.5))
            ticks.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            let first = floor(viewport.start / step) * step
            let count = Int(ceil(viewport.span / step)) + 1
            for index in 0...count {
                let time = first + Double(index) * step
                let x = viewport.x(at: time)
                let middle = x + step * viewport.scale / 2
                ticks.move(to: CGPoint(x: x, y: size.height - 7))
                ticks.addLine(to: CGPoint(x: x, y: size.height))
                ticks.move(to: CGPoint(x: middle, y: size.height - 4))
                ticks.addLine(to: CGPoint(x: middle, y: size.height))
                if x >= -0.01, x + 64 <= size.width {
                    context.draw(Text(timelineTime(time)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary), at: CGPoint(x: x + 4, y: 9), anchor: .leading)
                }
            }
            context.stroke(ticks, with: .color(.secondary.opacity(0.42)), lineWidth: 1)
        }
        .frame(width: viewport.width, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { editor.seek(to: viewport.time(at: $0.location.x)) })
    }

    private func markerLane(_ viewport: TimelineViewport) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(WorkbenchStyle.lane)
            Canvas { context, _ in
                for marker in editor.manifest.timelineMarkers where marker.time >= viewport.start && marker.time <= viewport.end {
                    let center = CGPoint(x: viewport.x(at: marker.time), y: Self.markerHeight / 2)
                    let diamond = Path { path in
                        path.move(to: CGPoint(x: center.x, y: center.y - 4))
                        path.addLine(to: CGPoint(x: center.x + 4, y: center.y))
                        path.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                        path.addLine(to: CGPoint(x: center.x - 4, y: center.y))
                        path.closeSubpath()
                    }
                    context.fill(diamond, with: .color(WorkbenchStyle.marker))
                }
            }
        }
        .frame(width: viewport.width, height: Self.markerHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { editor.seek(to: viewport.time(at: $0.location.x)) })
    }

    private func lane(kind: TrackKind, in viewport: TimelineViewport) -> some View {
        let row = Self.rowHeight(tall: tall)
        let clips = editor.manifest.timelineClips.filter { $0.kind == kind && viewport.shows($0) }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(WorkbenchStyle.lane)
                .frame(width: viewport.width, height: row)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded {
                    editor.selectTrack(kind)
                    editor.seek(to: viewport.time(at: $0.location.x))
                })
            ForEach(editor.gaps(on: kind).filter { $0.upperBound > viewport.start && $0.lowerBound < viewport.end }, id: \.self) { gap in
                gapTarget(gap, on: kind, in: viewport, height: row)
            }
            ForEach(clips) { clip in
                TimelineTile(clip: clip, viewport: viewport, row: row, snapping: snap, autoCloseGaps: autoCloseGaps,
                             thumbnails: thumbnails, editor: editor)
            }
        }
        .frame(width: viewport.width, height: row)
        .clipped()
    }

    private func gapTarget(_ gap: Range<Double>, on kind: TrackKind, in viewport: TimelineViewport, height: CGFloat) -> some View {
        let left = max(0, viewport.x(at: gap.lowerBound))
        let width = min(viewport.width, viewport.x(at: gap.upperBound)) - left
        return Rectangle().fill(.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded {
                editor.selectTrack(kind)
                editor.seek(to: viewport.time(at: left + $0.location.x))
            })
            .contextMenu {
                Button("删除空隙并合拢各轨") { editor.deleteGap(gap, on: kind) }
                Text("各轨同时剪去这段时间。")
            }
            .accessibilityLabel("\(kind.title)空隙，\(timelineTime(gap.lowerBound))至\(timelineTime(gap.upperBound))")
            .accessibilityAction(named: Text("删除空隙并合拢各轨")) { editor.deleteGap(gap, on: kind) }
            .position(x: left + width / 2, y: height / 2)
    }

    private func playhead(_ viewport: TimelineViewport) -> some View {
        Canvas { context, size in
            let x = viewport.x(at: editor.playhead)
            guard x >= 0, x <= size.width else { return }
            let y = Self.rulerHeight - 7
            let indicator = Path { path in
                path.move(to: CGPoint(x: x - 4, y: y))
                path.addLine(to: CGPoint(x: x + 4, y: y))
                path.addLine(to: CGPoint(x: x, y: y + 6))
                path.closeSubpath()
            }
            let needle = Path { path in
                path.move(to: CGPoint(x: x, y: y + 5))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.fill(indicator, with: .color(WorkbenchStyle.accent))
            context.stroke(needle, with: .color(WorkbenchStyle.accent), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TextCueTile: View {
    let cue: SubtitleCue
    let viewport: TimelineViewport
    let snapping: Bool
    let height: CGFloat
    let duration: Double
    let playhead: Double
    let selected: Bool
    let enabled: Bool
    let color: Color
    let select: (Bool) -> Void
    let update: (SubtitleCue) -> Void
    @State private var draft: SubtitleCue?

    private enum Edge { case start, center, end }

    var body: some View {
        let displayed = draft ?? cue
        let x = viewport.x(at: displayed.start)
        let end = max(x + 5, viewport.x(at: displayed.end))
        let left = draft == nil ? max(0, x) : clamp(x, 0, viewport.width - 2)
        let right = draft == nil ? min(viewport.width, end) : clamp(end, left + 2, viewport.width)
        let width = right - left
        if width > 0 {
            let grip = min(9, width / 4)
            HStack(spacing: 0) {
                handle(.start, width: x >= 0 ? grip : 0)
                Text(displayed.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(dragging(.center))
                    .simultaneousGesture(TapGesture().onEnded { select(true) })
                handle(.end, width: end <= viewport.width ? grip : 0)
            }
            .frame(width: width, height: height - 6)
            .background(color.opacity(selected ? 0.28 : 0.15))
            .overlay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(selected ? 0.92 : 0.25))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(enabled ? 1 : 0.55)
            .offset(x: left, y: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cue.text)
            .accessibilityAction { select(true) }
        }
    }

    private func handle(_ edge: Edge, width: Double) -> some View {
        Rectangle().fill(color.opacity(selected ? 0.27 : 0.08))
            .frame(width: width)
            .overlay { if selected, width > 3 { Capsule().fill(.primary.opacity(0.55)).frame(width: 2, height: 10) } }
            .contentShape(Rectangle())
            .gesture(dragging(edge))
            .help(edge == .start ? "拖动调整入点" : "拖动调整出点")
    }

    private func dragging(_ edge: Edge) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if !selected { select(false) }
                let shift = value.translation.width / viewport.scale
                let minimum = min(cue.end - cue.start, SubtitleCue.minimumDuration)
                var next = cue
                switch edge {
                case .start:
                    next.end = min(cue.end, duration)
                    next.start = clamp(snapped(cue.start + shift), 0, max(0, next.end - minimum))
                case .end:
                    next.start = min(cue.start, max(0, duration - minimum))
                    next.end = clamp(snapped(cue.end + shift), next.start + minimum, duration)
                case .center:
                    let length = min(duration, cue.end - cue.start)
                    next.start = clamp(snapped(cue.start + shift), 0, max(0, duration - length))
                    next.end = next.start + length
                }
                draft = next
            }
            .onEnded { _ in
                if let draft { update(draft) }
                draft = nil
            }
    }

    private func snapped(_ time: Double) -> Double {
        snapping && abs(time - playhead) * viewport.scale <= 8 ? playhead : time
    }
}

private struct TimelineTile: View {
    let clip: TimelineClip
    let viewport: TimelineViewport
    let row: CGFloat
    let snapping: Bool
    let autoCloseGaps: Bool
    let thumbnails: [TimelineThumbnail: CGImage]
    @ObservedObject var editor: TakeEditorModel
    @State private var drag: TimelineClip?

    private var displayed: TimelineClip { drag ?? clip }
    private var selected: Bool { clip.id == editor.selectedClipID }
    private var clipX: Double { viewport.x(at: displayed.at) }
    private var clipWidth: Double { max(8, displayed.length * viewport.scale) }
    private var left: Double { clamp(clipX, 0, viewport.width) }
    private var right: Double { clamp(clipX + clipWidth, left, viewport.width) }
    private var width: Double { right - left }
    private var handleWidth: Double { min(10, max(3, clipWidth / 4)) }

    var body: some View {
        if width > 0 { tile }
    }

    private var tile: some View {
        HStack(spacing: 0) {
            trimHandle(left: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(clip.title)
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        .layoutPriority(1)
                    if clip.fullFrame == true, width > 92 {
                        Text("全屏").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if clip.kind.isVideo, width > 145 {
                        Text(timelineTime(displayed.length))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if clip.kind.isVideo { Spacer(minLength: 0) }
                else { waveform }
            }
            .padding(.horizontal, 4)
            .padding(.top, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(move)
            .simultaneousGesture(TapGesture().onEnded { editor.select(clip) })
            trimHandle(left: false)
        }
        .frame(width: width, height: row - 6)
        .background(alignment: .bottom) {
            if clip.kind.isVideo {
                TimelineFilmstrip(cells: TimelineFilmstrip.cells(for: displayed, in: viewport), images: thumbnails)
                    .frame(height: row - 22)
            }
        }
        .background(clip.kind.color.opacity(selected ? 0.29 : 0.16), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(clip.kind.color.opacity(selected ? 1 : 0.37),
                                                               lineWidth: selected ? 1.6 : 0.8)
            .allowsHitTesting(false))
        .opacity(editor.manifest.edit(clip.kind).enabled && clip.hidden != true ? 1 : 0.42)
        .position(x: left + width / 2, y: row / 2)
        .zIndex(drag != nil ? 2 : (selected ? 1 : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.kind.title)，\(clip.title)，从 \(timelineTime(displayed.at)) 到 \(timelineTime(displayed.end))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.select(clip) }
        .contextMenu {
            if clip.kind.isCamera {
                Button(clip.fullFrame == true ? "恢复画中画" : "此片段人像全屏") {
                    editor.setCameraFullFrame(clip, clip.fullFrame != true)
                }
                .disabled(clip.hidden == true || !editor.manifest.edit(clip.kind).enabled)
            }
        }
    }

    private var waveform: some View {
        Canvas { context, size in
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: size.height / 2))
            axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(axis, with: .color(clip.kind.color.opacity(0.32)), lineWidth: 1)
            guard let values = editor.waveforms[clip.file], !values.peaks.isEmpty else { return }
            let first = displayed.sourceStart + (left - clipX) / viewport.scale
            let visibleLength = min(displayed.sourceEnd - first, width / viewport.scale)
            guard visibleLength > 0 else { return }
            let columns = max(1, min(1_200, Int(size.width / 2)))
            let step = visibleLength / Double(columns)
            var peaks = Path()
            for index in 0..<columns {
                let from = first + Double(index) * step
                let amplitude = pow(Double(values.peak(from: from, to: from + step)), 0.62)
                let x = (Double(index) + 0.5) * size.width / Double(columns)
                let middle = size.height / 2
                let height = max(0.6, amplitude * middle)
                peaks.move(to: CGPoint(x: x, y: middle - height))
                peaks.addLine(to: CGPoint(x: x, y: middle + height))
            }
            context.stroke(peaks, with: .color(clip.kind.color.opacity(0.95)), lineWidth: 1.3)
        }
        .frame(maxHeight: .infinity)
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                editor.select(clip)
                drag = ClipEdit.moved(clip, to: clip.at + value.translation.width / viewport.scale,
                                      among: editor.manifest.timelineClips, playhead: editor.playhead, snap: threshold)
            }
            .onEnded { _ in finishDrag() }
    }

    private func trimHandle(left: Bool) -> some View {
        let handle = left ? clamp(clipX + handleWidth - self.left, 0, width)
            : clamp(right - (clipX + clipWidth - handleWidth), 0, width)
        return Rectangle().fill(clip.kind.color.opacity(selected ? 0.28 : 0.09))
            .frame(width: handle)
            .overlay {
                if selected {
                    Capsule().fill(.primary.opacity(0.55)).frame(width: 2, height: row * 0.30)
                }
            }
            .contentShape(Rectangle())
            .help(left ? "拖动左端裁切" : "拖动右端裁切")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    editor.select(clip)
                    let edge = (left ? clip.at : clip.end) + value.translation.width / viewport.scale
                    drag = ClipEdit.trimmed(clip, left: left, to: edge, among: editor.manifest.timelineClips,
                                            playhead: editor.playhead, snap: threshold)
                }
                .onEnded { _ in finishDrag(closingTrimGap: autoCloseGaps) })
    }

    private var threshold: Double { snapping ? 8 / viewport.scale : 0 }

    private func finishDrag(closingTrimGap: Bool = false) {
        if let drag { editor.editClip(drag, closingTrimGap: closingTrimGap) }
        drag = nil
    }
}
