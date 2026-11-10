@preconcurrency import AVFoundation
import Foundation

struct PointerSample: Codable, Equatable, Sendable {
    let time: Double
    let x: Double
    let y: Double
    var visible = true
}

struct PointerClick: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let time: Double
    let x: Double
    let y: Double
    var manual = false
}

struct PointerTrace: Codable, Equatable, Sendable {
    var samples: [PointerSample] = []
    var clicks: [PointerClick] = []
}

struct ScreenRecording: Codable, Equatable, Sendable {
    var pointer: PointerTrace
    let cursorAppearance: CursorAppearance?
    var keyboard: KeyboardTrace?

    var drawsEditableCursor: Bool {
        (cursorAppearance ?? (pointer.samples.isEmpty ? .system : .editable)) == .editable
    }
}

enum CursorStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case arrow = "白色箭头", darkArrow = "黑色箭头", dot = "强调圆点", ring = "空心圆环"
    case crosshair = "准星", hand = "手指", hidden = "隐藏"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "箭头": self = .arrow
        case "圆点": self = .dot
        default:
            guard let style = Self(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown cursor style"))
            }
            self = style
        }
    }
    var id: Self { self }
}

enum CameraCorner: String, CaseIterable, Identifiable, Codable, Sendable {
    case bottomRight = "右下", bottomLeft = "左下", topRight = "右上", topLeft = "左上"
    var id: Self { self }
}

enum CameraShape: String, CaseIterable, Identifiable, Codable, Sendable {
    case circle = "圆形人像", rounded = "圆角人像"
    var id: Self { self }
}

enum ClickSound: String, CaseIterable, Identifiable, Codable, Sendable {
    case mechanical = "机械咔哒", soft = "轻触", crisp = "清脆按键", bell = "短提示音"
    var id: Self { self }
}

struct EffectSettings: Codable, Equatable, Sendable {
    var autoZoom = true
    var zoom = 1.65
    var hold = 0.85
    var transition = 0.32
    var blur = 2.0
    var followPointer = true
    var cursor = CursorStyle.arrow
    var cursorSize = 1.0
    var smoothing = 0.09
    var cursorTrail = false
    var ripple = true
    var clickSound = false
    var clickVolume = 0.25
    var soundChoice: ClickSound?
    var clickPreset: ClickSound { soundChoice ?? .bell }
    var cameraCorner = CameraCorner.bottomRight
    var cameraSize = 0.24
    var personShape: CameraShape?
    var cameraShape: CameraShape { personShape ?? .rounded }
    var personMirrored: Bool?
    var cameraMirrored: Bool { personMirrored ?? false }
    var portraitLighting: PortraitLighting?
    var showKeyboard: Bool?
    var keyboardCorner: CameraCorner?
}

struct TrackEdit: Codable, Equatable, Sendable {
    var enabled = true
    var start: Double
    var end: Double
    var offset = 0.0
    var volume = 1.0
}

struct TakeManifest: Codable, Equatable, Sendable {
    var version = 1
    let duration: Double
    var tracks: [TrackKind]
    var edits: [TrackKind: TrackEdit]
    var sourceOffsets: [TrackKind: Double] = [:]
    var effects = EffectSettings()
    var pointer: PointerTrace
    var flattened = false
    var clips: [TimelineClip]?
    var extraFocus: [String: [PointerClick]]?
    var cursorAppearance: CursorAppearance?
    var duckSystemAudio: Bool?
    var baseTracks: [TrackKind]?
    var appendedScreens: [String: ScreenRecording]?
    var keyboard: KeyboardTrace?
    var presentation: PresentationSettings?
    var subtitles: [SubtitleCue]?
    var subtitleStyle: SubtitleStyle?
    var cameraNames: [TrackKind: String]?
    var cameraMirrors: [TrackKind: Bool]?

    var timelineClips: [TimelineClip] { clips ?? [] }
    var timelineDuration: Double { timelineClips.map(\.end).max() ?? 0 }
    var assetFiles: Set<String> {
        var files = Set((baseTracks ?? tracks).map(\.filename)).union(timelineClips.map(\.file))
        if let background = presentation?.portrait.backgroundAsset { files.insert(background) }
        return files
    }
    var canvasSettings: PresentationSettings { presentation ?? PresentationSettings() }
    var subtitleCues: [SubtitleCue] { subtitles ?? [] }
    var captionStyle: SubtitleStyle { subtitleStyle ?? SubtitleStyle() }
    var cameraTracks: [TrackKind] { tracks.filter(\.isCamera) }
    func trackTitle(_ kind: TrackKind) -> String {
        kind.isCamera && cameraTracks.count > 1 ? kind.angleTitle : kind.title
    }
    func trackDescription(_ kind: TrackKind) -> String {
        if let name = cameraNames?[kind] { return "\(trackTitle(kind)) · \(name)" }
        return trackTitle(kind)
    }
    func cameraMirrored(_ kind: TrackKind) -> Bool {
        kind == .camera ? effects.cameraMirrored : cameraMirrors?[kind] == true
    }
    var drawsEditableCursor: Bool {
        timelineClips.contains { $0.kind == .screen && screenRecording(for: $0.file)?.drawsEditableCursor == true }
    }
    var hasNarrationTracks: Bool { tracks.contains(.microphone) && tracks.contains(where: \.isBackgroundAudio) }
    var hasKeyboardPresses: Bool {
        timelineClips.contains { clip in
            clip.kind == .screen && screenRecording(for: clip.file)?.keyboard?
                .presses(in: clip.sourceStart..<clip.sourceEnd).isEmpty == false
        }
    }
    var hasKeyboardTrack: Bool {
        timelineClips.contains { $0.kind == .screen && screenRecording(for: $0.file)?.keyboard != nil }
    }

    func screenRecording(for file: String) -> ScreenRecording? {
        if file == TrackKind.screen.filename, !flattened {
            return ScreenRecording(pointer: pointer, cursorAppearance: cursorAppearance, keyboard: keyboard)
        }
        return appendedScreens?[file]
    }

    func keyboardPresses(in range: Range<Double>) -> [RecordedKeyPress] {
        timelineClips.flatMap { clip -> [RecordedKeyPress] in
            guard clip.kind == .screen, let keys = screenRecording(for: clip.file)?.keyboard else { return [] }
            let lower = max(clip.at, range.lowerBound)
            let upper = min(clip.end, range.upperBound)
            guard lower < upper else { return [] }
            let offset = clip.at - clip.sourceStart
            return keys.presses(in: (lower - offset)..<(upper - offset)).map {
                RecordedKeyPress(time: $0.time + offset, label: $0.label)
            }
        }.sorted { $0.time < $1.time }
    }

    init(duration: Double, tracks: [TrackKind], pointer: PointerTrace = PointerTrace(), flattened: Bool = false) {
        self.duration = duration
        self.tracks = tracks
        edits = Dictionary(uniqueKeysWithValues: tracks.map { ($0, TrackEdit(start: 0, end: duration)) })
        self.pointer = pointer
        self.flattened = flattened
    }

    func edit(_ kind: TrackKind) -> TrackEdit {
        var value = edits[kind] ?? TrackEdit(start: 0, end: duration)
        value.start = min(max(0, value.start), max(0, duration - 0.05))
        value.end = min(max(value.start + 0.05, value.end), duration)
        value.offset = kind == .screen ? 0 : min(max(value.offset, -duration), duration)
        value.volume = clamp(value.volume, 0, kind.maximumVolume)
        return value
    }

    mutating func applyNarrationMix() {
        guard hasNarrationTracks else { return }
        var microphone = edit(.microphone)
        microphone.volume = max(microphone.volume, 1)
        edits[.microphone] = microphone
        for kind in tracks where kind.isBackgroundAudio {
            var background = edit(kind)
            background.volume = min(background.volume, 0.30)
            edits[kind] = background
        }
        duckSystemAudio = true
    }
}

struct RecordedMedia: Sendable {
    let folder: URL
    let tracks: [TrackKind]
    let missing: [TrackKind]
    var sourceOffsets: [TrackKind: Double] = [:]
    var interruptedCameras: [TrackKind] = []
    var cameraNames: [TrackKind: String] = [:]
    var pointer = PointerTrace()
    var personShape: CameraShape = .rounded
    var mirrorCamera = false
    var cursorAppearance: CursorAppearance?
    var prioritizeNarration = false
    var portraitLighting: PortraitLighting?
    var microphoneGain = 1.0
    var keyboard: KeyboardTrace?
    var showsKeyboard: Bool?
}

struct TakeProject: Sendable {
    let folder: URL
    let isTemporary: Bool
    let manifest: TakeManifest
    var stagedFiles: [String: URL] = [:]

    private static let manifestName = "project.json"

    func source(_ kind: TrackKind) -> URL { source(kind.filename) }
    func source(_ filename: String) -> URL { stagedFiles[filename] ?? folder.appendingPathComponent(filename) }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskTake-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func fromRecording(_ media: RecordedMedia) async throws -> Self {
        let duration = try await durationOfScreen(in: media.folder)
        var manifest = TakeManifest(duration: duration, tracks: media.tracks, pointer: media.pointer)
        manifest.sourceOffsets = media.sourceOffsets
        if !media.cameraNames.isEmpty { manifest.cameraNames = media.cameraNames.filter { media.tracks.contains($0.key) } }
        manifest.effects.personShape = media.personShape
        manifest.effects.personMirrored = media.mirrorCamera
        manifest.effects.portraitLighting = media.portraitLighting
        if media.tracks.contains(.microphone) {
            manifest.edits[.microphone]?.volume = clamp(media.microphoneGain, 0, TrackKind.microphone.maximumVolume)
        }
        manifest.effects.soundChoice = .mechanical
        manifest.cursorAppearance = media.cursorAppearance
        manifest.keyboard = media.keyboard
        manifest.effects.showKeyboard = media.showsKeyboard
        if media.prioritizeNarration { manifest.applyNarrationMix() }
        let timeline = try await makeTimeline(from: manifest, in: media.folder)
        return Self(folder: media.folder, isTemporary: true, manifest: timeline)
    }

    static func load(_ url: URL) async throws -> Self {
        if url.pathExtension.lowercased() == "mp4" {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 0.05,
                  try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw RecorderError.message("无法从这个 MP4 读取画面。")
            }
            let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            let temporary = try temporaryFolder()
            do {
                try FileManager.default.copyItem(at: url, to: temporary.appendingPathComponent(TrackKind.screen.filename))
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            let tracks: [TrackKind] = hasAudio ? [.screen, .originalAudio] : [.screen]
            do {
                let manifest = TakeManifest(duration: duration, tracks: tracks, flattened: true)
                return Self(folder: temporary, isTemporary: true,
                            manifest: try await makeTimeline(from: manifest, in: temporary))
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        let data = try Data(contentsOf: url.appendingPathComponent(manifestName))
        let manifest = try JSONDecoder().decode(TakeManifest.self, from: data)
        guard [1, 2].contains(manifest.version), manifest.duration.isFinite, manifest.duration >= 0.05,
              manifest.tracks.first == .screen, Set(manifest.tracks).count == manifest.tracks.count,
              (manifest.baseTracks?.first ?? .screen) == .screen,
              manifest.assetFiles.allSatisfy({ isAssetName($0) &&
                  FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) else {
            throw RecorderError.message("工程格式或素材不完整。")
        }
        let captions = manifest.subtitleCues
        guard Set(captions.map(\.id)).count == captions.count,
              captions.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.end.isFinite }) else {
            throw RecorderError.message("工程的字幕时间线不可读。")
        }
        if let clips = manifest.clips {
            guard Set(clips.map(\.id)).count == clips.count, clips.allSatisfy({ clip in
                isMediaName(clip.file) && manifest.tracks.contains(clip.kind) &&
                    clip.at >= 0 && clip.length >= TimelineClip.minimumLength - 0.00001 &&
                    clip.sourceStart >= clip.mediaStart - 0.00001 && clip.sourceEnd <= clip.mediaEnd + 0.00001 &&
                    clip.end.isFinite
            }), manifest.tracks.allSatisfy({ kind in
                let lane = clips.filter { $0.kind == kind }.sorted { $0.at < $1.at }
                return zip(lane, lane.dropFirst()).allSatisfy { $0.end <= $1.at + 0.00001 }
            }) else { throw RecorderError.message("工程的片段时间线不可读。") }
            return Self(folder: url, isTemporary: false, manifest: manifest)
        }
        return Self(folder: url, isTemporary: false, manifest: try await makeTimeline(from: manifest, in: url))
    }

    private static func isAssetName(_ filename: String) -> Bool {
        if filename.hasPrefix("background-"), filename.hasSuffix(".png") {
            return UUID(uuidString: String(filename.dropFirst(11).dropLast(4))) != nil
        }
        return isMediaName(filename)
    }

    private static func isMediaName(_ filename: String) -> Bool {
        if TrackKind.allCases.contains(where: { $0.filename == filename }) { return true }
        if filename.hasPrefix("import-"), filename.hasSuffix(".mp4") {
            return UUID(uuidString: String(filename.dropFirst(7).dropLast(4))) != nil
        }
        guard filename.hasPrefix("take-"), filename.hasSuffix(".mp4") || filename.hasSuffix(".m4a") else { return false }
        return UUID(uuidString: String(filename.dropFirst(5).dropLast(4))) != nil
    }

    private static func makeTimeline(from manifest: TakeManifest, in folder: URL) async throws -> TakeManifest {
        var upgraded = manifest
        let screenEdit = manifest.edit(.screen)
        let screenURL = folder.appendingPathComponent(TrackKind.screen.filename)
        let screen = try await mediaRange(at: screenURL, kind: .screen)
        let origin = max(screen.start.seconds, screenEdit.start)
        let limit = min(screen.end.seconds, screenEdit.end)
        var clips: [TimelineClip] = []
        for kind in manifest.tracks {
            let edit = manifest.edit(kind)
            let url = folder.appendingPathComponent(kind.filename)
            let range = kind == .screen ? screen : try await mediaRange(at: url, kind: kind)
            let clock = manifest.sourceOffsets[kind] ?? 0
            let start = max(edit.start, clock + range.start.seconds, origin - edit.offset)
            let end = min(edit.end, clock + range.end.seconds, limit - edit.offset)
            guard end - start >= TimelineClip.minimumLength - 0.00001 else { continue }
            clips.append(TimelineClip(kind: kind, file: kind.filename, title: manifest.cameraNames?[kind] ?? kind.title,
                                      mediaStart: range.start.seconds, mediaEnd: range.end.seconds,
                                      sourceStart: start - clock, length: end - start,
                                      at: max(0, start + edit.offset - origin)))
        }
        upgraded.version = 2
        upgraded.clips = clips
        return upgraded
    }

    static func importClips(from url: URL, name: String, at time: Double) async throws -> [TimelineClip] {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("这个文件没有可用的视频轨。")
        }
        let title = url.deletingPathExtension().lastPathComponent
        let videoRange = try await video.load(.timeRange)
        guard videoRange.duration.seconds.isFinite, videoRange.duration.seconds >= 0.05 else {
            throw RecorderError.message("这个文件的画面太短。")
        }
        var clips = [TimelineClip(kind: .screen, file: name, title: title,
                                  mediaStart: videoRange.start.seconds, mediaEnd: videoRange.end.seconds,
                                  sourceStart: videoRange.start.seconds, length: videoRange.duration.seconds, at: time)]
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let range = try await audio.load(.timeRange)
            let start = max(range.start.seconds, videoRange.start.seconds)
            let end = min(range.end.seconds, videoRange.end.seconds)
            if end - start >= TimelineClip.minimumLength {
                clips.append(TimelineClip(kind: .originalAudio, file: name, title: title,
                                          mediaStart: range.start.seconds, mediaEnd: range.end.seconds,
                                          sourceStart: start, length: end - start,
                                          at: time + start - videoRange.start.seconds))
            }
        }
        return clips
    }

    private static func mediaRange(at url: URL, kind: TrackKind) async throws -> CMTimeRange {
        let type: AVMediaType = kind.isVideo ? .video : .audio
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        guard let track = try await asset.loadTracks(withMediaType: type).first else {
            throw RecorderError.message("无法读取\(kind.title)素材。")
        }
        return try await track.load(.timeRange)
    }

    func save(_ settings: TakeManifest, to destination: URL) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        if !isTemporary && destination.standardizedFileURL == folder.standardizedFileURL {
            let files = FileManager.default
            var copied: [URL] = []
            do {
                for filename in settings.assetFiles where stagedFiles[filename] != nil {
                    let target = folder.appendingPathComponent(filename)
                    let stage = folder.appendingPathComponent(".DeskTake-\(UUID())")
                    defer { try? files.removeItem(at: stage) }
                    try files.copyItem(at: source(filename), to: stage)
                    try files.moveItem(at: stage, to: target)
                    copied.append(target)
                }
                try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
            } catch {
                for url in copied { try? files.removeItem(at: url) }
                throw error
            }
        } else {
            let files = FileManager.default
            let stageFolder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: destination, create: true)
            defer { try? files.removeItem(at: stageFolder) }
            let stage = stageFolder.appendingPathComponent("TakeRec.desktake", isDirectory: true)
            try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for filename in settings.assetFiles {
                try files.copyItem(at: source(filename), to: stage.appendingPathComponent(filename))
            }
            try data.write(to: stage.appendingPathComponent(Self.manifestName), options: .atomic)
            try files.moveItem(at: stage, to: destination)
        }
        return Self(folder: destination, isTemporary: false, manifest: settings)
    }

    func cleanUp() {
        if isTemporary { try? FileManager.default.removeItem(at: folder) }
    }

    private static func durationOfScreen(in folder: URL) async throws -> Double {
        let asset = AVURLAsset(url: folder.appendingPathComponent(TrackKind.screen.filename))
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.05 else {
            throw RecorderError.message("录制太短，请录制至少一秒后再停止。")
        }
        return duration
    }
}
