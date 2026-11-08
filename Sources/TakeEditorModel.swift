import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

extension UTType {
    static let deskTakeProject = UTType(exportedAs: "local.takerec.desktake-project", conformingTo: .package)
}

@MainActor
final class TakeEditorModel: ObservableObject {
    @Published var manifest: TakeManifest { didSet { schedulePreview() } }
    @Published var selectedTrack = TrackKind.screen
    @Published private(set) var selectedClipID: UUID?
    @Published private(set) var playhead = 0.0
    @Published private(set) var playing = false
    @Published private(set) var activity: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastExport: URL?
    @Published private(set) var previewSize = CGSize(width: 16, height: 9)
    @Published private(set) var previewReady = false
    @Published private(set) var waveforms: [String: AudioWaveform] = [:]
    @Published private(set) var hasUndo = false

    let player = AVPlayer()
    private(set) var project: TakeProject
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("DeskTake-editor-\(UUID())", isDirectory: true)
    private var preview: MovieTimeline?
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var observer: Any?
    private var undo: [TakeManifest] = []
    private var appendedTakes: [TakeProject] = []
    private var clickPreview: NSSound?

    init(project: TakeProject, note: String? = nil, checkMicrophone: Bool = false) {
        self.project = project
        manifest = project.manifest
        notice = note
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playing, let preview = self.preview, time.isNumeric else { return }
                self.playhead = clamp(time.seconds, 0, preview.length)
                if self.player.rate == 0, time.seconds >= preview.length - 0.10 { self.playing = false }
            }
        }
        schedulePreview()
        loadWaveforms(checking: checkMicrophone ? TrackKind.microphone.filename : nil)
    }

    var hasUnsavedProject: Bool { project.isTemporary || manifest != project.manifest }
    var isBusy: Bool { activity != nil }
    var duration: Double { max(0.10, manifest.timelineDuration) }
    var selectedClip: TimelineClip? { manifest.timelineClips.first { $0.id == selectedClipID } }

    func select(_ clip: TimelineClip) {
        if selectedTrack != clip.kind { selectedTrack = clip.kind }
        if selectedClipID != clip.id { selectedClipID = clip.id }
    }

    func selectTrack(_ track: TrackKind) {
        selectedTrack = track
        if selectedClip?.kind != track { selectedClipID = nil }
    }

    func setTrackEnabled(_ kind: TrackKind, _ enabled: Bool) {
        var edit = manifest.edit(kind)
        guard edit.enabled != enabled else { return }
        edit.enabled = enabled
        manifest.edits[kind] = edit
        if playing { schedulePreview(continuePlaying: true) }
    }

    func setTrackVolume(_ kind: TrackKind, _ volume: Double) {
        var edit = manifest.edit(kind)
        let gain = clamp((volume * 100).rounded() / 100, 0, kind.maximumVolume)
        guard edit.volume != gain else { return }
        edit.volume = gain
        manifest.edits[kind] = edit
        if playing { schedulePreview(continuePlaying: true) }
    }

    func canSplit(allTracks: Bool) -> Bool {
        manifest.timelineClips.contains {
            (allTracks || $0.kind == selectedTrack) && playhead - $0.at >= TimelineClip.minimumLength
                && $0.end - playhead >= TimelineClip.minimumLength
        }
    }

    func split(allTracks: Bool) {
        let (clips, selected) = ClipEdit.split(manifest.timelineClips, at: playhead,
                                                kind: allTracks ? nil : selectedTrack)
        commit(clips, selecting: selected)
    }

    func editClip(_ clip: TimelineClip) {
        var clips = manifest.timelineClips
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index] = clip
        commit(clips, selecting: clip.id)
    }

    func deleteClip(closeGap: Bool) {
        guard let clip = selectedClip else { return }
        let clips = closeGap ? ClipEdit.removeTime(from: clip.at, to: clip.end, in: manifest.timelineClips)
            : manifest.timelineClips.filter { $0.id != clip.id }
        commit(clips, selecting: nil)
        if closeGap { seek(to: clip.at) }
    }

    func packTrack() {
        commit(ClipEdit.packed(manifest.timelineClips, kind: selectedTrack), selecting: selectedClipID)
    }

    func undoClips() {
        guard let previous = undo.popLast() else { return }
        pause()
        var restored = manifest
        restored.clips = previous.clips
        restored.tracks = previous.tracks
        restored.baseTracks = previous.baseTracks
        restored.appendedScreens = previous.appendedScreens.map { screens in
            let current = manifest.appendedScreens?.filter { screens[$0.key] != nil } ?? [:]
            return screens.merging(current) { _, current in current }
        }
        let removed = manifest.assetFiles.subtracting(restored.assetFiles)
        for file in removed { restored.extraFocus?.removeValue(forKey: file) }
        manifest = restored
        if selectedClip == nil { selectedClipID = nil }
        playhead = min(playhead, duration)
        hasUndo = !undo.isEmpty
    }

    private func commit(_ clips: [TimelineClip], selecting id: UUID?) {
        var next = manifest
        next.clips = clips
        commitTimeline(next, selecting: id)
    }

    private func commitTimeline(_ next: TakeManifest, selecting id: UUID?) {
        let clips = next.timelineClips
        guard manifest.timelineClips != clips else { return }
        pause()
        undo.append(manifest)
        if undo.count > 40 { undo.removeFirst() }
        hasUndo = true
        manifest = next
        if let id, let selected = clips.first(where: { $0.id == id }) { select(selected) }
        else { selectedClipID = nil }
        playhead = min(playhead, duration)
    }

    func pauseForRecording() { pause() }

    func reportRecording(_ message: String) { notice = message }

    func appendRecording(_ take: TakeProject, note: String?) throws {
        let sourceClips = take.manifest.timelineClips
        guard !isBusy, let screen = sourceClips.first(where: { $0.kind == .screen }) else {
            throw RecorderError.message("这段续录没有可追加的屏幕素材。")
        }
        let start = manifest.timelineDuration
        let names = Dictionary(uniqueKeysWithValues: Set(sourceClips.map(\.file)).map { file in
            (file, "take-\(UUID()).\(URL(fileURLWithPath: file).pathExtension)")
        })
        let additions = sourceClips.map { clip in
            TimelineClip(kind: clip.kind, file: names[clip.file]!, title: "续录 · \(clip.kind.title)",
                         mediaStart: clip.mediaStart, mediaEnd: clip.mediaEnd,
                         sourceStart: clip.sourceStart, length: clip.length, at: start + clip.at)
        }
        var next = manifest
        next.baseTracks = next.baseTracks ?? next.tracks
        next.tracks += take.manifest.tracks.filter { kind in
            !manifest.tracks.contains(kind) && additions.contains { $0.kind == kind }
        }
        if next.tracks.contains(.microphone), !manifest.tracks.contains(.microphone) {
            var microphone = next.edit(.microphone)
            microphone.volume = take.manifest.edit(.microphone).volume
            next.edits[.microphone] = microphone
        }
        next.clips = manifest.timelineClips + additions
        if let recorded = take.manifest.screenRecording(for: screen.file), let name = names[screen.file] {
            var screens = next.appendedScreens ?? [:]
            screens[name] = recorded
            next.appendedScreens = screens
        }
        for (file, name) in names { project.stagedFiles[name] = take.source(file) }
        appendedTakes.append(take)
        commitTimeline(next, selecting: additions.first(where: { $0.kind == .screen })?.id)
        seek(to: start)
        notice = ["续录已接到时间线末尾。", note].compactMap { $0 }.joined(separator: " ")
        loadWaveforms(checking: additions.first(where: { $0.kind == .microphone })?.file)
    }

    func importMovie() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "追加 MP4 素材"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canChooseDirectories = false
        activity = "选择追加素材"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                self.activity = nil
                return
            }
            self.appendMovie(url)
        }
    }

    func makeAgentBundle() {
        guard !isBusy, manifest.timelineClips.contains(where: { $0.kind.isVideo }) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择存放 Agent 素材包的文件夹"
        panel.prompt = "生成素材包"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        activity = "选择素材包位置"
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { self.activity = nil; return }
            self.writeAgentBundle(in: parent)
        }
    }

    private func writeAgentBundle(in parent: URL) {
        pause()
        activity = "正在整理 Agent 素材包"
        let source = project
        let settings = manifest
        Task {
            defer { activity = nil }
            do {
                let folder = try await Task.detached(priority: .userInitiated) {
                    try AgentHandoff.makeBundle(project: source, manifest: settings, in: parent)
                }.value
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setString(AgentHandoff.prompt(for: folder), forType: .string)
                notice = "素材包已生成 · \(folder.lastPathComponent)。\(copied ? "提示词已复制，粘贴给你的 Agent 即可。" : "请把包内的 AGENT.md 提供给你的 Agent。")"
            } catch {
                notice = "生成 Agent 素材包失败。\(error.localizedDescription)"
            }
        }
    }

    func importAgentPlan() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 Agent 剪辑方案"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        activity = "选择剪辑方案"
        panel.begin { response in
            self.activity = nil
            guard response == .OK, let url = panel.url else { return }
            do {
                let plan = try AgentHandoff.readPlan(url)
                let clips = try AgentHandoff.apply(plan, to: self.manifest)
                if clips == self.manifest.timelineClips {
                    self.notice = "方案里没有需要删除的时段。"
                } else {
                    self.commit(clips, selecting: nil)
                    self.notice = "Agent 剪辑已应用 · 删除 \(plan.cuts.count) 个时段，可预览或撤销。"
                }
            } catch {
                self.notice = "导入剪辑方案失败。\(error.localizedDescription)"
            }
        }
    }

    private func appendMovie(_ url: URL) {
        activity = "正在读入素材"
        let filename = "import-\(UUID()).mp4"
        let target = cache.appendingPathComponent(filename)
        let time = manifest.timelineDuration
        Task {
            defer { activity = nil }
            do {
                let new = try await TakeProject.importClips(from: url, name: filename, at: time)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try FileManager.default.copyItem(at: url, to: target)
                }.value
                project.stagedFiles[filename] = target
                var next = manifest
                if new.contains(where: { $0.kind == .originalAudio }), !next.tracks.contains(.originalAudio) {
                    next.tracks.append(.originalAudio)
                }
                next.clips = next.timelineClips + new
                commitTimeline(next, selecting: new.first?.id)
                seek(to: time)
                loadWaveforms()
            } catch {
                try? FileManager.default.removeItem(at: target)
                notice = "追加素材失败。\(error.localizedDescription)"
            }
        }
    }

    func close() {
        previewTask?.cancel()
        waveformTask?.cancel()
        clickPreview?.stop()
        pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        project.cleanUp()
        for take in appendedTakes { take.cleanUp() }
        appendedTakes.removeAll()
        try? FileManager.default.removeItem(at: cache)
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        pause()
        playhead = clamp(time, 0, duration)
        updatePreviewPosition()
    }

    private func updatePreviewPosition() {
        guard let preview else { return }
        let end = max(0, preview.length - 1 / Double(CaptureSize.framesPerSecond))
        player.seek(to: CMTime(seconds: clamp(playhead, 0, end), preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        if playing {
            pause()
        } else if let preview {
            if playhead >= preview.length - 0.05 { seek(to: 0) }
            playing = true
            player.play()
        }
    }

    private func pause() {
        player.pause()
        playing = false
    }

    private func schedulePreview(continuePlaying: Bool = false) {
        previewTask?.cancel()
        let settings = manifest
        let source = project
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(160))
                let timeline = try await MovieExport.timeline(for: source, manifest: settings, cache: cache,
                                                              microphoneWaveforms: waveforms)
                try Task.checkCancellation()
                let resume = continuePlaying && playing
                pause()
                preview = timeline
                previewSize = timeline.video.renderSize
                player.replaceCurrentItem(with: timeline.playerItem())
                updatePreviewPosition()
                previewReady = true
                if resume {
                    playing = true
                    player.play()
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    pause()
                    preview = nil
                    player.replaceCurrentItem(with: nil)
                    previewReady = false
                    notice = "预览暂不可用。\(error.localizedDescription)"
                }
            }
        }
    }

    private func loadWaveforms(checking microphone: String? = nil) {
        waveformTask?.cancel()
        let files = Set(manifest.timelineClips.filter { !$0.kind.isVideo }.map(\.file))
        let microphones = Set(manifest.timelineClips.filter { $0.kind == .microphone }.map(\.file))
        let ordered = microphones.sorted() + files.subtracting(microphones).sorted()
        let source = project
        waveformTask = Task {
            for file in ordered where waveforms[file] == nil {
                guard !Task.isCancelled else { return }
                do {
                    let waveform = try await AudioWaveform.read(source.source(file))
                    try Task.checkCancellation()
                    waveforms[file] = waveform
                    if file == microphone, (waveform.peaks.max() ?? 0) < 0.003 {
                        let hint = "这段麦克风轨几乎无声。请检查输入设备、静音开关和录制前的电平。"
                        notice = [notice, hint].compactMap { $0 }.joined(separator: " ")
                    }
                    if microphones.contains(file), manifest.duckSystemAudio == true {
                        schedulePreview(continuePlaying: true)
                    }
                } catch is CancellationError { return }
                catch { waveforms[file] = AudioWaveform(interval: 0.02, peaks: []) }
            }
        }
    }

    func auditionClick() {
        do {
            let file = try ClickAudio.file(for: manifest.effects.clickPreset, in: cache)
            clickPreview?.stop()
            let sound = NSSound(contentsOf: file, byReference: true)
            sound?.volume = Float(manifest.effects.clickVolume)
            clickPreview = sound
            sound?.play()
        } catch {
            notice = "音效试听失败。\(error.localizedDescription)"
        }
    }

    func addFocus(at location: CGPoint) {
        guard let preview, let span = preview.instruction.screen(at: playhead) else { return }
        let motion = span.motion?.frame(at: playhead) ?? MotionEffects.Frame()
        let bounds = CGRect(origin: .zero, size: previewSize)
        let display = CGPoint(x: location.x * bounds.width, y: (1 - location.y) * bounds.height)
        let source = display.applying(motion.pan(in: bounds).inverted())
        let click = PointerClick(time: span.clip.sourceStart + playhead - span.clip.at,
                                 x: clamp(source.x / bounds.width, 0, 1), y: clamp(1 - source.y / bounds.height, 0, 1), manual: true)
        if span.clip.file == TrackKind.screen.filename {
            manifest.pointer.clicks.append(click)
        } else {
            var focus = manifest.extraFocus ?? [:]
            focus[span.clip.file, default: []].append(click)
            manifest.extraFocus = focus
        }
    }

    func nearestFocus() -> TimelineMarker? {
        guard let nearest = manifest.timelineMarkers.min(by: { abs($0.time - playhead) < abs($1.time - playhead) }),
              abs(nearest.time - playhead) <= 0.20 else { return nil }
        return nearest
    }

    func removeFocus() {
        guard let nearest = nearestFocus() else { return }
        if nearest.clip.file == TrackKind.screen.filename {
            manifest.pointer.clicks.removeAll { $0.id == nearest.click.id }
        } else if manifest.appendedScreens?[nearest.clip.file]?.pointer.clicks.contains(where: { $0.id == nearest.click.id }) == true {
            manifest.appendedScreens?[nearest.clip.file]?.pointer.clicks.removeAll { $0.id == nearest.click.id }
        } else {
            manifest.extraFocus?[nearest.clip.file]?.removeAll { $0.id == nearest.click.id }
        }
    }

    func jumpFocus(next: Bool) {
        let times = manifest.timelineMarkers.map(\.time)
        let time = next ? times.first { $0 > playhead + 0.04 } : times.last { $0 < playhead - 0.04 }
        if let time { seek(to: time) }
    }

    func saveProject() {
        guard !isBusy else { return }
        if !project.isTemporary {
            writeProject(to: project.folder)
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存录屏工程"
        panel.prompt = "保存工程"
        panel.allowedContentTypes = [.deskTakeProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "录屏 \(Self.fileStamp()).desktake"
        activity = "选择工程位置"
        panel.begin { response in
            if response == .OK, let url = panel.url { self.writeProject(to: url) }
            else { self.activity = nil }
        }
    }

    private func writeProject(to url: URL) {
        pause()
        activity = "正在保存工程"
        let source = project
        let settings = manifest
        Task {
            defer { activity = nil }
            do {
                project = try await Task.detached(priority: .userInitiated) { try source.save(settings, to: url) }.value
                project.stagedFiles = source.stagedFiles.filter { !settings.assetFiles.contains($0.key) }
                if source.isTemporary {
                    player.replaceCurrentItem(with: nil)
                    source.cleanUp()
                }
                schedulePreview()
                notice = "工程已保存 · \(url.lastPathComponent)"
            } catch {
                notice = "保存工程失败。\(error.localizedDescription)"
            }
        }
    }

    func export() {
        guard !isBusy, manifest.timelineClips.contains(where: { $0.kind.isVideo }) else { return }
        let panel = NSSavePanel()
        panel.title = "导出成片"
        panel.prompt = "导出 MP4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "录屏 \(Self.fileStamp()).mp4"
        let quality = NSPopUpButton()
        let choices = VideoResolution.allCases
        quality.addItems(withTitles: choices.map { resolution in
            guard previewReady, let size = try? resolution.size(for: previewSize) else { return resolution.rawValue }
            return "\(resolution.rawValue) 上限 · \(size.pixelLabel) px"
        })
        let hdSize = try? VideoResolution.hd.size(for: previewSize)
        quality.selectItem(at: previewReady && hdSize?.dimensions == previewSize ? 0 : 1)
        quality.setAccessibilityLabel("成片分辨率")
        let accessory = NSStackView(views: [NSTextField(labelWithString: "成片分辨率"), quality])
        accessory.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        panel.accessoryView = accessory
        activity = "选择导出位置"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                self.activity = nil
                return
            }
            let index = quality.indexOfSelectedItem
            self.render(to: url, resolution: choices.indices.contains(index) ? choices[index] : .uhd)
        }
    }

    private func render(to url: URL, resolution: VideoResolution) {
        if url.standardizedFileURL.path.hasPrefix(project.folder.standardizedFileURL.path + "/") {
            activity = nil
            notice = "请把成片导出到工程文件夹之外。"
            return
        }
        pause()
        activity = "正在导出 MP4"
        let settings = manifest
        Task {
            defer { activity = nil }
            do {
                let timeline = try await MovieExport.timeline(for: project, manifest: settings, cache: cache,
                                                              resolution: resolution)
                try await MovieExport.save(timeline, to: url)
                lastExport = url
                notice = "MP4 已导出 · \(url.lastPathComponent)"
            } catch {
                notice = "导出失败。\(error.localizedDescription)"
            }
        }
    }

    private static func fileStamp() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmmss"
        return format.string(from: .now)
    }
}
