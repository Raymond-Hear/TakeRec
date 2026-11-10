import AppKit
@preconcurrency import AVFoundation
import CoreImage
import UniformTypeIdentifiers

extension UTType {
    static let deskTakeProject = UTType(exportedAs: "local.takerec.desktake-project", conformingTo: .package)
}

@MainActor
final class TakeEditorModel: ObservableObject {
    @Published var manifest: TakeManifest { didSet { schedulePreview() } }
    @Published var selectedTrack = TrackKind.screen
    @Published private(set) var selectedClipID: UUID?
    @Published private(set) var selectedSubtitleID: UUID?
    @Published private(set) var playhead = 0.0
    @Published private(set) var playing = false
    @Published private(set) var activity: String?
    @Published private(set) var notice: String?
    @Published private(set) var subtitleActivity: String?
    @Published private(set) var subtitleNotice: String?
    @Published private(set) var lastExport: URL?
    @Published private(set) var lastQuickExport: URL?
    @Published private(set) var lastAgentBundle: URL?
    @Published private(set) var previewSize = CGSize(width: 16, height: 9)
    @Published private(set) var previewReady = false
    @Published private(set) var waveforms: [String: AudioWaveform] = [:]
    @Published private(set) var hasUndo = false

    let player = AVPlayer()
    let thumbnailCache = TimelineThumbnailCache()
    private(set) var project: TakeProject
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("DeskTake-editor-\(UUID())", isDirectory: true)
    private var preview: MovieTimeline?
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var observer: Any?
    private enum UndoEdit {
        case timeline(TakeManifest, captionsChanged: Bool)
        case captions([SubtitleCue]?)
    }
    private var undo: [UndoEdit] = []
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
    var isBusy: Bool { activity != nil || subtitleActivity != nil }
    var canMakeAgentBundle: Bool { manifest.timelineClips.contains(where: { $0.kind.isVideo }) }
    var duration: Double { max(0.10, manifest.timelineDuration) }
    var selectedClip: TimelineClip? { manifest.timelineClips.first { $0.id == selectedClipID } }
    var selectedSubtitle: SubtitleCue? { manifest.subtitleCues.first { $0.id == selectedSubtitleID } }
    var sourceAspect: CGFloat { preview?.instruction.sourceAspect ?? 16.0 / 9 }

    var canvas: PresentationSettings {
        get { manifest.canvasSettings }
        set { if newValue != canvas { manifest.presentation = newValue } }
    }

    var captionStyle: SubtitleStyle {
        get { manifest.captionStyle }
        set { if newValue != captionStyle { manifest.subtitleStyle = newValue } }
    }

    func select(_ clip: TimelineClip) {
        if selectedSubtitleID != nil { selectedSubtitleID = nil }
        if selectedTrack != clip.kind { selectedTrack = clip.kind }
        if selectedClipID != clip.id { selectedClipID = clip.id }
    }

    func selectTrack(_ track: TrackKind) {
        if selectedSubtitleID != nil { selectedSubtitleID = nil }
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

    func setCameraMirror(_ kind: TrackKind, _ enabled: Bool) {
        if kind == .camera {
            manifest.effects.personMirrored = enabled
        } else {
            var mirrors = manifest.cameraMirrors ?? [:]
            mirrors[kind] = enabled ? true : nil
            manifest.cameraMirrors = mirrors.isEmpty ? nil : mirrors
        }
    }

    func setCameraClipVisible(_ clip: TimelineClip, _ visible: Bool) {
        guard clip.kind.isCamera else { return }
        var changed = clip
        changed.hidden = visible ? nil : true
        editClip(changed)
    }

    func canSwitchCamera(to kind: TrackKind) -> Bool {
        manifest.cameraTracks.count > 1 && manifest.edit(kind).enabled && cameraAtPlayhead(kind) != nil
    }

    func switchCamera(to kind: TrackKind) {
        guard canSwitchCamera(to: kind), let target = cameraAtPlayhead(kind) else { return }
        let start = playhead
        let end = target.end
        let clips = manifest.timelineClips
        let (splitAtStart, _) = ClipEdit.split(clips.filter { $0.kind.isCamera }, at: start, kind: nil)
        let (segments, _) = ClipEdit.split(splitAtStart, at: end, kind: nil)
        let tolerance = TimelineClip.minimumLength / 2
        let angles = segments.map { clip in
            guard clip.end > start + tolerance, clip.at < end - tolerance else { return clip }
            var changed = clip
            changed.hidden = clip.kind == kind ? nil : true
            return changed
        }
        let selected = angles.first { $0.kind == kind && $0.contains(start) }
        commit(clips.filter { !$0.kind.isCamera } + angles, selecting: selected?.id)
    }

    private func cameraAtPlayhead(_ kind: TrackKind) -> TimelineClip? {
        manifest.timelineClips.first { $0.kind == kind && $0.contains(playhead) }
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
        if closeGap {
            var next = manifest
            next.clips = ClipEdit.removeTime(from: clip.at, to: clip.end, in: manifest.timelineClips)
            next.subtitles = next.subtitles?.compactMap { $0.removingTime(from: clip.at, to: clip.end) }
            commitTimeline(next, selecting: nil)
            seek(to: clip.at)
        } else {
            commit(manifest.timelineClips.filter { $0.id != clip.id }, selecting: nil)
        }
    }

    func packTrack() {
        commit(ClipEdit.packed(manifest.timelineClips, kind: selectedTrack), selecting: selectedClipID)
    }

    func undoClips() {
        guard let edit = undo.popLast() else { return }
        pause()
        switch edit {
        case .timeline(let previous, let captionsChanged):
            var restored = manifest
            restored.clips = previous.clips
            restored.tracks = previous.tracks
            restored.baseTracks = previous.baseTracks
            restored.cameraNames = previous.cameraNames
            restored.appendedScreens = previous.appendedScreens.map { screens in
                let current = manifest.appendedScreens?.filter { screens[$0.key] != nil } ?? [:]
                return screens.merging(current) { _, current in current }
            }
            if captionsChanged { restored.subtitles = previous.subtitles }
            for file in manifest.assetFiles.subtracting(restored.assetFiles) {
                restored.extraFocus?.removeValue(forKey: file)
            }
            manifest = restored
        case .captions(let previous):
            manifest.subtitles = previous
        }
        if selectedClip == nil { selectedClipID = nil }
        if selectedSubtitle == nil { selectedSubtitleID = nil }
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
        recordUndo(.timeline(manifest, captionsChanged: manifest.subtitles != next.subtitles))
        manifest = next
        if let id, let selected = clips.first(where: { $0.id == id }) { select(selected) }
        else { selectedClipID = nil }
        if selectedSubtitle == nil { selectedSubtitleID = nil }
        playhead = min(playhead, duration)
    }

    private func recordUndo(_ edit: UndoEdit) {
        undo.append(edit)
        if undo.count > 40 { undo.removeFirst() }
        hasUndo = true
    }

    func pauseForRecording() { pause() }

    func reportRecording(_ message: String) { notice = message }

    var keyboardVisible: Bool {
        get { manifest.effects.showKeyboard != false }
        set { manifest.effects.showKeyboard = newValue }
    }

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
            TimelineClip(kind: clip.kind, file: names[clip.file]!, title: "续录 · \(clip.title)",
                         mediaStart: clip.mediaStart, mediaEnd: clip.mediaEnd,
                         sourceStart: clip.sourceStart, length: clip.length, at: start + clip.at)
        }
        var next = manifest
        next.baseTracks = next.baseTracks ?? next.tracks
        next.tracks += take.manifest.tracks.filter { kind in
            !manifest.tracks.contains(kind) && additions.contains { $0.kind == kind }
        }
        let angles = TrackKind.cameraTracks.filter { next.tracks.contains($0) }
        next.tracks = [.screen] + angles + next.tracks.filter { !$0.isVideo }
        var cameraNames = next.cameraNames ?? [:]
        for kind in take.manifest.cameraTracks where additions.contains(where: { $0.kind == kind }) {
            let name = take.manifest.cameraNames?[kind]
            if !manifest.cameraTracks.contains(kind) { cameraNames[kind] = name }
            else if name != cameraNames[kind] { cameraNames.removeValue(forKey: kind) }
        }
        next.cameraNames = cameraNames.isEmpty ? nil : cameraNames
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
            if !manifest.hasKeyboardTrack, recorded.keyboard != nil {
                next.effects.showKeyboard = take.manifest.effects.showKeyboard
            }
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
        guard !isBusy, canMakeAgentBundle else { return }
        let panel = NSOpenPanel()
        panel.title = "选择存放 Agent 素材包的文件夹"
        panel.message = "素材包包含当前工程和分轨原片。"
        panel.prompt = "生成素材包"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        activity = "选择素材包位置"
        presentAgentPicker(panel) { response in
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
                lastAgentBundle = folder
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
        panel.prompt = "导入方案"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.directoryURL = lastAgentBundle
        activity = "选择剪辑方案"
        presentAgentPicker(panel) { response in
            self.activity = nil
            guard response == .OK, let url = panel.url else { return }
            do {
                let plan = try AgentHandoff.readPlan(url)
                let clips = try AgentHandoff.apply(plan, to: self.manifest)
                if clips == self.manifest.timelineClips {
                    self.notice = "方案里没有需要删除的时段。"
                } else {
                    var next = self.manifest
                    next.clips = clips
                    for cut in plan.cuts.sorted(by: { $0.start > $1.start }) {
                        next.subtitles = next.subtitles?.compactMap { $0.removingTime(from: cut.start, to: cut.end) }
                    }
                    self.commitTimeline(next, selecting: nil)
                    self.notice = "Agent 剪辑已应用 · 删除 \(plan.cuts.count) 个时段，可预览或撤销。"
                }
            } catch {
                self.notice = "导入剪辑方案失败。\(error.localizedDescription)"
            }
        }
    }

    private func presentAgentPicker(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
                    if file == microphone, !waveform.hasAudibleInput {
                        let hint = "录下的麦克风信号很弱。可以先静音系统声，单听麦克风轨。"
                        notice = [notice, hint].compactMap { $0 }.joined(separator: " ")
                    }
                    if microphones.contains(file), manifest.duckSystemAudio == true {
                        schedulePreview(continuePlaying: true)
                    }
                } catch is CancellationError { return }
                catch {
                    waveforms[file] = AudioWaveform(interval: 0.02, peaks: [])
                    if file == microphone {
                        notice = [notice, "麦克风素材无法解码。"].compactMap { $0 }.joined(separator: " ")
                    }
                }
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
        let canvas = CGRect(origin: .zero, size: previewSize)
        let screen = preview.instruction.presentation.screenBounds(in: canvas, sourceAspect: sourceAspect)
        let display = CGPoint(x: location.x * canvas.width, y: (1 - location.y) * canvas.height)
        guard screen.contains(display) else { return }
        let bounds = CGRect(origin: .zero, size: screen.size)
        let point = CGPoint(x: display.x - screen.minX, y: display.y - screen.minY)
        let source = point.applying(motion.pan(in: bounds).inverted())
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
        if canvas.framing == .portrait {
            let size = canvas.portrait.dimensions
            panel.message = "竖屏成片 · \(Int(size.width)) × \(Int(size.height)) px"
            activity = "选择导出位置"
            panel.begin { response in
                if response == .OK, let url = panel.url { self.render(to: url, resolution: .uhd) }
                else { self.activity = nil }
            }
            return
        }
        let quality = NSPopUpButton()
        let choices = VideoResolution.allCases
        quality.addItems(withTitles: choices.map { resolution in
            guard previewReady,
                  let size = try? canvas.renderSize(source: previewSize, scale: 1, resolution: resolution, proxy: false)
            else { return resolution.rawValue }
            return "\(resolution.rawValue) 上限 · \(Int(size.width)) × \(Int(size.height)) px"
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
        if isInsideProject(url) {
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

    private func isInsideProject(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(project.folder.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    private static func fileStamp() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmmss"
        return format.string(from: .now)
    }
}

extension TakeEditorModel {
    func selectSubtitle(_ cue: SubtitleCue, seek: Bool = true) {
        if selectedSubtitleID != cue.id { selectedSubtitleID = cue.id }
        if selectedClipID != nil { selectedClipID = nil }
        if seek { self.seek(to: cue.start) }
    }

    func updateSubtitle(_ cue: SubtitleCue, record: Bool = true) {
        var cues = manifest.subtitleCues
        guard let index = cues.firstIndex(where: { $0.id == cue.id }), cues[index] != cue else { return }
        cues[index] = cue
        setSubtitles(cues, record: record)
    }

    func deleteSubtitle() {
        guard let id = selectedSubtitleID else { return }
        setSubtitles(manifest.subtitleCues.filter { $0.id != id })
        selectedSubtitleID = nil
    }

    func addSubtitle() {
        let duration = manifest.timelineDuration
        guard duration > 0 else { return }
        let cue = SubtitleCue(start: playhead, end: playhead + 2, text: "新字幕")
            .placed(start: playhead, end: playhead + 2, duration: duration)
        setSubtitles(manifest.subtitleCues + [cue])
        selectSubtitle(cue)
    }

    private func setSubtitles(_ cues: [SubtitleCue], record: Bool = true) {
        if record { recordUndo(.captions(manifest.subtitles)) }
        manifest.subtitles = cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    func importSubtitles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 SRT 或 TXT 字幕"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), .plainText].compactMap { $0 }
        if !manifest.subtitleCues.isEmpty {
            panel.message = "本次导入会替换字幕轨上的字幕。可以用撤销恢复。"
        }
        subtitleNotice = nil
        subtitleActivity = "选择字幕文件"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { self.subtitleActivity = nil; return }
            self.subtitleActivity = "读取字幕"
            let duration = self.manifest.timelineDuration
            Task {
                defer { self.subtitleActivity = nil }
                do {
                    let imported = try await Task.detached { try SubtitleImport.read(url, duration: duration) }.value
                    self.setSubtitles(imported.cues)
                    if let first = imported.cues.first { self.selectSubtitle(first) }
                    let detail = imported.needsTiming ? " · 已按文字量分配时间，可拖动校准" : " · 已读取时间码"
                    self.subtitleNotice = "已导入 \(imported.cues.count) 条字幕" + detail
                } catch {
                    self.subtitleNotice = "导入字幕失败。\(error.localizedDescription)"
                }
            }
        }
    }

    func importCanvasBackground() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择竖屏背景图片"
        panel.allowedContentTypes = [.image]
        activity = "选择背景图片"
        panel.begin { response in
            defer { self.activity = nil }
            guard response == .OK, let url = panel.url else { return }
            do {
                let picture = try CanvasBackground.importedImage(at: url)
                guard let data = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else {
                    throw RecorderError.message("无法保存背景图片。")
                }
                let file = "background-\(UUID().uuidString).png"
                try FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
                let staged = self.cache.appendingPathComponent(file)
                try data.write(to: staged, options: .atomic)
                let previous = self.canvas.portrait.backgroundAsset
                self.project.stagedFiles[file] = staged
                self.canvas.portrait.backgroundAsset = file
                self.canvas.portrait.background = .image
                if let previous, let discarded = self.project.stagedFiles.removeValue(forKey: previous) {
                    try? FileManager.default.removeItem(at: discarded)
                }
                self.notice = "已导入竖屏背景 · \(url.lastPathComponent)"
            } catch {
                self.notice = "导入背景失败。\(error.localizedDescription)"
            }
        }
    }

    func exportCanvasBackground() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "导出竖屏底板"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "竖屏底板 \(Self.fileStamp()).png"
        activity = "选择底板位置"
        panel.begin { response in
            defer { self.activity = nil }
            guard response == .OK, let url = panel.url else { return }
            guard !self.isInsideProject(url) else {
                self.notice = "请把底板导出到工程文件夹之外。"
                return
            }
            do {
                let settings = self.canvas
                let bounds = CGRect(origin: .zero, size: settings.portrait.dimensions)
                let imported = try MovieExport.backgroundImage(for: self.project, settings: settings)
                let image = settings.portrait.background.render(in: bounds, imported: imported)
                try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                self.notice = "底板已导出 · \(url.lastPathComponent)"
            } catch {
                self.notice = "导出底板失败。\(error.localizedDescription)"
            }
        }
    }

    func quickExport(audioOnly: Bool) {
        guard !isBusy, canMakeAgentBundle else { return }
        let panel = NSSavePanel()
        let format = audioOnly ? "M4A" : "MP4"
        panel.title = audioOnly ? "导出转写音频" : "导出低清视频"
        panel.prompt = "导出 \(format)"
        panel.allowedContentTypes = [audioOnly ? .mpeg4Audio : .mpeg4Movie]
        panel.nameFieldStringValue = "转写用 \(Self.fileStamp()).\(format.lowercased())"
        subtitleNotice = nil
        subtitleActivity = "选择临时导出位置"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { self.subtitleActivity = nil; return }
            guard !self.isInsideProject(url) else {
                self.subtitleActivity = nil
                self.subtitleNotice = "请把临时文件导出到工程文件夹之外。"
                return
            }
            self.pause()
            self.subtitleActivity = "正在导出 \(format)"
            let settings = self.manifest
            Task {
                defer { self.subtitleActivity = nil }
                do {
                    let timeline = try await MovieExport.timeline(for: self.project, manifest: settings, cache: self.cache,
                                                                  proxy: true, audioOnly: audioOnly)
                    try await MovieExport.save(timeline, to: url, audioOnly: audioOnly)
                    self.lastQuickExport = url
                } catch {
                    self.subtitleNotice = "临时导出失败。\(error.localizedDescription)"
                }
            }
        }
    }
}
