@preconcurrency import AVFoundation
import Darwin
import Foundation

struct MovieTimeline {
    let composition: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVAudioMix?
    let instruction: TakeInstruction
    let length: Double
    private let sources: [AVURLAsset]

    init(composition: AVMutableComposition, video: AVMutableVideoComposition, audio: AVAudioMix?,
         instruction: TakeInstruction, length: Double, sources: [AVURLAsset]) {
        self.composition = composition
        self.video = video
        self.audio = audio
        self.instruction = instruction
        self.length = length
        self.sources = sources
    }

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = video
        item.audioMix = audio
        return item
    }
}

enum MovieExport {
    static func timeline(for project: TakeProject, manifest: TakeManifest, cache: URL,
                         resolution: VideoResolution = .uhd,
                         microphoneWaveforms: [String: AudioWaveform]? = nil) async throws -> MovieTimeline {
        let composition = AVMutableComposition()
        let clips = manifest.timelineClips.sorted { $0.at < $1.at }
        guard clips.contains(where: { $0.kind.isVideo }),
              manifest.timelineDuration >= TimelineClip.minimumLength - 0.00001 else {
            throw RecorderError.message("请在时间线上放一段画面素材。")
        }
        let length = time(manifest.timelineDuration)
        let primary = AVURLAsset(url: project.source(.screen))
        var assets: [String: AVURLAsset] = [TrackKind.screen.filename: primary]
        guard let sourceCanvas = try await primary.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("无法读取工程画布。")
        }
        let baseSize = try await orientedSize(for: sourceCanvas)
        var canvasScale: CGFloat = 1
        var screenID: CMPersistentTrackID?
        var cameraID: CMPersistentTrackID?
        var screens: [VideoSpan] = []
        var cameras: [VideoSpan] = []
        var levels: [(kind: TrackKind?, track: AVCompositionTrack, gain: Double)] = []

        for kind in manifest.tracks {
            let edit = manifest.edit(kind)
            let lane = clips.filter { $0.kind == kind }
            // Keep video timing when every picture track is hidden, so audio-only preview still has a canvas.
            guard !lane.isEmpty, kind.isVideo || (edit.enabled && edit.volume > 0) else { continue }
            let type: AVMediaType = kind.isVideo ? .video : .audio
            guard let destination = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecorderError.message("无法建立\(kind.title)轨。")
            }
            var sources: [String: AVAssetTrack] = [:]
            for clip in lane {
                try Task.checkCancellation()
                let source: AVAssetTrack
                if let loaded = sources[clip.file] {
                    source = loaded
                } else {
                    let asset = assets[clip.file] ?? AVURLAsset(url: project.source(clip.file))
                    assets[clip.file] = asset
                    source = try await sourceTrack(asset, clip: clip)
                    sources[clip.file] = source
                    if kind == .screen && clip.file != TrackKind.screen.filename {
                        let size = try await orientedSize(for: source)
                        // Keep the project aspect ratio and retain detail from higher-resolution additions.
                        canvasScale = max(canvasScale, size.width / baseSize.width, size.height / baseSize.height)
                    }
                }
                let span = CMTimeRange(start: time(clip.sourceStart), duration: time(clip.length))
                do {
                    try destination.insertTimeRange(span, of: source, at: time(clip.at))
                } catch {
                    throw RecorderError.message("无法插入「\(clip.title)」片段。\(error.localizedDescription)")
                }

                if kind == .screen && edit.enabled {
                    let transform = try await source.load(.preferredTransform)
                    screens.append(VideoSpan(clip: clip, transform: transform,
                                             motion: motion(for: clip, manifest: manifest),
                                             drawsCursor: manifest.screenRecording(for: clip.file)?.drawsEditableCursor == true))
                } else if kind == .camera && edit.enabled {
                    cameras.append(VideoSpan(clip: clip, transform: try await source.load(.preferredTransform)))
                }
            }
            if kind.isVideo {
                let end = destination.timeRange.end
                if end < length {
                    destination.insertEmptyTimeRange(CMTimeRange(start: end, end: length))
                }
                if kind == .screen { screenID = destination.trackID }
                else { cameraID = destination.trackID }
            } else {
                levels.append((kind, destination, edit.volume))
            }
        }

        guard screenID != nil || cameraID != nil else {
            throw RecorderError.message("无法建立画面时间线。")
        }
        if manifest.effects.clickSound {
            let markers = manifest.timelineMarkers
            if !markers.isEmpty,
               let sound = try await addClickAudio(markers, to: composition, cache: cache,
                                                    preset: manifest.effects.clickPreset, end: length.seconds) {
                levels.append((nil, sound, clamp(manifest.effects.clickVolume, 0, 1)))
            }
        }

        let instruction = TakeInstruction(timeRange: CMTimeRange(start: .zero, duration: length),
                                          screenID: screenID, cameraID: cameraID, screens: screens, cameras: cameras,
                                          settings: manifest.effects)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = TakeCompositor.self
        video.renderSize = try resolution.size(for: baseSize, scale: canvasScale).dimensions
        video.frameDuration = CMTime(value: 1, timescale: CaptureSize.framesPerSecond)
        video.instructions = [instruction]

        var duckedRegions: [SpeechDucking.Region] = []
        if manifest.duckSystemAudio == true,
           let microphoneGain = levels.first(where: { $0.kind == .microphone })?.gain,
           levels.contains(where: { $0.kind?.isBackgroundAudio == true }) {
            let microphones = clips.filter { $0.kind == .microphone }
            var analysis = microphoneWaveforms ?? [:]
            if microphoneWaveforms == nil {
                for file in Set(microphones.map(\.file)) {
                    try Task.checkCancellation()
                    analysis[file] = try await AudioWaveform.read(project.source(file))
                }
            }
            duckedRegions = SpeechDucking.regions(for: microphones, waveforms: analysis, boost: max(1, microphoneGain))
        }

        let mix = AVMutableAudioMix()
        // A boosted microphone is limited before mixing. Count its capped contribution once.
        let headroom = max(1, levels.reduce(0) { $0 + min(1, $1.gain) })
        mix.inputParameters = try levels.map { level in
            let input = AVMutableAudioMixInputParameters(track: level.track)
            let volume = Float(min(1, level.gain) / headroom)
            if level.kind == .microphone, level.gain > 1 {
                input.audioTapProcessor = try MicrophoneBoost.makeTap(gain: level.gain)
            }
            if level.kind?.isBackgroundAudio == true {
                SpeechDucking.apply(to: input, volume: volume, duration: length.seconds, regions: duckedRegions)
            } else {
                input.setVolume(volume, at: .zero)
            }
            return input
        }
        return MovieTimeline(composition: composition, video: video, audio: levels.isEmpty ? nil : mix,
                             instruction: instruction, length: length.seconds, sources: Array(assets.values))
    }

    private static func sourceTrack(_ asset: AVURLAsset, clip: TimelineClip) async throws -> AVAssetTrack {
        let type: AVMediaType = clip.kind.isVideo ? .video : .audio
        guard let track = try await asset.loadTracks(withMediaType: type).first else {
            throw RecorderError.message("工程中的「\(clip.title)」素材不可读。")
        }
        return track
    }

    private static func orientedSize(for track: AVAssetTrack) async throws -> CGSize {
        let transform = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        return CGRect(origin: .zero, size: size).applying(transform).standardized.size
    }

    private static func motion(for clip: TimelineClip, manifest: TakeManifest) -> MotionEffects {
        let delta = clip.at - clip.sourceStart
        let samples = manifest.screenRecording(for: clip.file)?.pointer.samples ?? []
        let trace = PointerTrace(
            samples: samples.filter { $0.time >= clip.sourceStart && $0.time < clip.sourceEnd }.map {
                PointerSample(time: $0.time + delta, x: $0.x, y: $0.y, visible: $0.visible)
            },
            clicks: manifest.clicks(in: clip).map {
                PointerClick(id: $0.id, time: $0.time + delta, x: $0.x, y: $0.y, manual: $0.manual)
            }
        )
        return MotionEffects(settings: manifest.effects, pointer: trace)
    }

    static func save(_ timeline: MovieTimeline, to destination: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: timeline.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.message("无法启动 MP4 导出。")
        }
        exporter.videoComposition = timeline.video
        exporter.audioMix = timeline.audio
        exporter.shouldOptimizeForNetworkUse = true

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".DeskTake-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await exporter.export(to: staging, as: .mp4)
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func addClickAudio(_ markers: [TimelineMarker], to composition: AVMutableComposition,
                                      cache: URL, preset: ClickSound, end: Double) async throws -> AVCompositionTrack? {
        let file = try ClickAudio.file(for: preset, in: cache)
        let asset = AVURLAsset(url: file)
        guard let sound = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let soundLength = try await sound.load(.timeRange).duration.seconds
        var lastEnd = 0.0
        for marker in markers where marker.time >= lastEnd && marker.time < end {
            let span = min(soundLength, end - marker.time)
            guard span >= 0.006 else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: time(span)),
                                      of: sound, at: time(marker.time))
            lastEnd = marker.time + span
        }
        return track
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
}
