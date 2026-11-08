import SwiftUI

struct ClipTimelineView: View {
    @ObservedObject var editor: TakeEditorModel
    @ObservedObject var shortcuts: ShortcutPreferences
    let maximumLaneHeight: CGFloat
    @State private var zoom = 1.0
    @State private var snap = true
    @State private var tall = false
    private let headerWidth: CGFloat = 113

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            GeometryReader { geometry in
                let visible = max(250, geometry.size.width - headerWidth - 14)
                let seconds = editor.duration + max(0.8, editor.duration * 0.08)
                let scale = max(visible / seconds, 9) * zoom
                let width = max(visible, seconds * scale)
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        headers
                        ScrollView(.horizontal) {
                            VStack(spacing: 4) {
                                ruler(width: width, scale: scale)
                                markerLane(width: width, scale: scale)
                                ForEach(editor.manifest.tracks) { kind in
                                    lane(kind: kind, width: width, scale: scale)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .scrollIndicators(.visible)
                    }
                }
                .scrollIndicators(.visible)
            }
            .frame(height: laneViewportHeight)
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var laneViewportHeight: CGFloat {
        let lanes = editor.manifest.tracks
        let rows = lanes.reduce(CGFloat.zero) { $0 + height($1) }
        let content = rows + 48 + 4 * CGFloat(lanes.count + 1) + 8
        return min(content, maximumLaneHeight)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("时间线").font(.headline)
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
                Button("删除所选片段  \(shortcuts[.deleteClip].label)") { editor.deleteClip(closeGap: false) }
                    .disabled(editor.selectedClip == nil)
                Button("删去所选时间并合拢所有轨道") { editor.deleteClip(closeGap: true) }
                    .disabled(editor.selectedClip == nil)
            } label: {
                Label { Text("片段") } icon: { DeskIcon("link-2", size: 13) }
            }
            .fixedSize()
            Button {
                editor.undoClips()
            } label: {
                DeskIcon("undo-2", size: 14)
            }
            .help("撤销片段操作 \(shortcuts[.undo].label)")
            .accessibilityLabel("撤销片段操作")
            .disabled(!editor.hasUndo)
            Spacer(minLength: 4)
            Toggle("吸附", isOn: $snap).toggleStyle(.checkbox)
            Toggle("加高", isOn: $tall).toggleStyle(.checkbox)
            Text("缩放").font(.caption).foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...6)
                .frame(width: 82)
                .help("时间线缩放")
                .accessibilityLabel("时间线缩放")
        }
        .controlSize(.small)
    }

    private var headers: some View {
        VStack(spacing: 4) {
            Text("轨道").font(.caption2.bold()).foregroundStyle(.secondary)
                .frame(width: headerWidth, height: 24, alignment: .leading)
            Label { Text("点击标记") } icon: { DeskIcon("mouse-pointer-2", size: 14) }
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: headerWidth, height: 24, alignment: .leading)
            ForEach(editor.manifest.tracks) { kind in
                HStack(spacing: 4) {
                    Button {
                        editor.selectTrack(kind)
                    } label: {
                        HStack(spacing: 5) {
                            DeskIcon(kind.icon, size: 14).foregroundStyle(kind.color)
                            Text(kind.title).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(editor.selectedTrack == kind ? kind.color : .primary)
                    trackSwitch(kind)
                }
                .padding(.trailing, 5)
                .frame(width: headerWidth, height: height(kind))
            }
        }
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
        .foregroundStyle(enabled ? Color.secondary : Color.orange)
        .help("\(action)\(kind.title)轨")
        .accessibilityLabel("\(action)\(kind.title)轨")
    }

    private func height(_ track: TrackKind) -> CGFloat {
        if tall { return 76 }
        return track.isVideo ? 48 : 59
    }

    private func ruler(width: CGFloat, scale: CGFloat) -> some View {
        let step = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * scale >= 62 } ?? 600
        return Canvas { context, size in
            for index in 0...min(10_000, Int((width / scale) / step)) {
                let time = Double(index) * step
                let x = time * scale
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 17))
                tick.addLine(to: CGPoint(x: x, y: 24))
                context.stroke(tick, with: .color(.secondary.opacity(0.5)))
                context.draw(Text(timelineTime(time)).font(.system(size: 10, design: .monospaced)),
                             at: CGPoint(x: x + 4, y: 8), anchor: .leading)
            }
        }
        .frame(width: width, height: 24)
        .overlay(alignment: .topLeading) { playhead(height: 24, scale: scale) }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { editor.seek(to: $0.location.x / scale) })
    }

    private func markerLane(width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(.background.opacity(0.55))
            Canvas { context, _ in
                for marker in editor.manifest.timelineMarkers {
                    let x = marker.time * scale
                    let point = CGRect(x: x - 3, y: 8, width: 6, height: 8)
                    context.fill(Path(roundedRect: point, cornerRadius: 2), with: .color(.orange))
                }
            }
            playhead(height: 24, scale: scale)
        }
        .frame(width: width, height: 24)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { editor.seek(to: $0.location.x / scale) })
    }

    private func lane(kind: TrackKind, width: CGFloat, scale: CGFloat) -> some View {
        let row = height(kind)
        let clips = editor.manifest.timelineClips.filter { $0.kind == kind }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.58))
                .frame(width: width, height: row)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded {
                    editor.selectTrack(kind)
                    editor.seek(to: $0.location.x / scale)
                })
            ForEach(clips) { clip in
                TimelineTile(clip: clip, scale: scale, row: row, snapping: snap, editor: editor)
            }
            playhead(height: row, scale: scale)
        }
        .frame(width: width, height: row)
        .clipped()
    }

    private func playhead(height: CGFloat, scale: CGFloat) -> some View {
        Rectangle().fill(Color.accentColor)
            .frame(width: 1.5, height: height)
            .offset(x: editor.playhead * scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TimelineTile: View {
    let clip: TimelineClip
    let scale: CGFloat
    let row: CGFloat
    let snapping: Bool
    @ObservedObject var editor: TakeEditorModel
    @State private var drag: TimelineClip?

    private var displayed: TimelineClip { drag ?? clip }
    private var selected: Bool { clip.id == editor.selectedClipID }
    private var width: CGFloat { max(8, displayed.length * scale) }

    var body: some View {
        HStack(spacing: 0) {
            trimHandle(left: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                if !clip.kind.isVideo {
                    waveform
                } else {
                    Text(timelineTime(displayed.length))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(move)
            .simultaneousGesture(TapGesture().onEnded { editor.select(clip) })
            trimHandle(left: false)
        }
        .frame(width: width, height: row - 6)
        .background(clip.kind.color.opacity(selected ? 0.36 : 0.23), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(clip.kind.color.opacity(selected ? 1 : 0.35),
                                                               lineWidth: selected ? 1.6 : 0.8)
            .allowsHitTesting(false))
        .opacity(editor.manifest.edit(clip.kind).enabled ? 1 : 0.42)
        .position(x: displayed.at * scale + width / 2, y: row / 2)
        .zIndex(drag != nil ? 2 : (selected ? 1 : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.kind.title)，\(clip.title)，从 \(timelineTime(displayed.at)) 到 \(timelineTime(displayed.end))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.select(clip) }
    }

    private var waveform: some View {
        Canvas { context, size in
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: size.height / 2))
            axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(axis, with: .color(clip.kind.color.opacity(0.32)), lineWidth: 1)
            guard let values = editor.waveforms[clip.file], !values.peaks.isEmpty else { return }
            let columns = max(1, min(1_200, Int(size.width / 2)))
            let step = displayed.length / Double(columns)
            var peaks = Path()
            for index in 0..<columns {
                let from = displayed.sourceStart + Double(index) * step
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
                drag = ClipEdit.moved(clip, to: clip.at + value.translation.width / scale,
                                      among: editor.manifest.timelineClips, playhead: editor.playhead, snap: threshold)
            }
            .onEnded { _ in finishDrag() }
    }

    private func trimHandle(left: Bool) -> some View {
        let handle = min(10, max(3, width / 4))
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
                    let edge = (left ? clip.at : clip.end) + value.translation.width / scale
                    drag = ClipEdit.trimmed(clip, left: left, to: edge, among: editor.manifest.timelineClips,
                                            playhead: editor.playhead, snap: threshold)
                }
                .onEnded { _ in finishDrag() })
    }

    private var threshold: Double { snapping ? 8 / scale : 0 }

    private func finishDrag() {
        if let drag { editor.editClip(drag) }
        drag = nil
    }
}
