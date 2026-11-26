@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MovieDemoSource {
    let folder: URL
    let title: String
    let videoRange: CMTimeRange
    let videoSize: CGSize
    let hasAudio: Bool
    let player: AVPlayer
    private var playbackObservers: [AnyCancellable] = []
    private var preserved = false

    private init(folder: URL, title: String, asset: AVURLAsset, range: CMTimeRange,
                 size: CGSize, hasAudio: Bool) {
        self.folder = folder
        self.title = title
        videoRange = range
        videoSize = size
        self.hasAudio = hasAudio
        let item = AVPlayerItem(asset: asset)
        item.forwardPlaybackEndTime = range.end
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.sourceClock = CMClockGetHostTimeClock()
        player.isMuted = true
    }

    static func load(_ url: URL) async throws -> MovieDemoSource {
        let folder = try TakeProject.temporaryFolder()
        let file = folder.appendingPathComponent(TrackKind.screen.filename)
        do {
            try await TakeProject.copyMovie(url, to: file)
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard try await asset.load(.isPlayable),
                  let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecorderError.message("这个 MP4 没有可播放的画面。")
            }
            let range = try await video.load(.timeRange)
            guard range.start.isNumeric, range.start >= .zero,
                  range.duration.isNumeric, range.duration.seconds >= 0.05 else {
                throw RecorderError.message("这个 MP4 的画面太短或时间信息不可读。")
            }
            let size = try await MovieExport.orientedSize(for: video)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw RecorderError.message("无法读取这个 MP4 的画面尺寸。")
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let hasAudio: Bool
            if let audio {
                hasAudio = try await audio.load(.timeRange).intersection(range).duration.seconds >= TimelineClip.minimumLength
            } else {
                hasAudio = false
            }
            let demo = MovieDemoSource(folder: folder, title: url.deletingPathExtension().lastPathComponent,
                                       asset: asset, range: range, size: size, hasAudio: hasAudio)
            try await demo.prepare()
            return demo
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func prepare() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while player.status == .unknown || player.currentItem?.status == .unknown {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard player.status == .readyToPlay, player.currentItem?.status == .readyToPlay,
              await player.seek(to: videoRange.start, toleranceBefore: .zero, toleranceAfter: .zero),
              await player.preroll(atRate: 1) else {
            throw player.currentItem?.error ?? player.error ?? RecorderError.message("MP4 预览未能就绪。")
        }
    }

    func start(at hostTime: CMTime, includesAudio: Bool, onEnd: @escaping @MainActor () -> Void,
               onFailure: @escaping @MainActor (Error) -> Void) {
        guard let item = player.currentItem, item.status == .readyToPlay else {
            onFailure(RecorderError.message("MP4 已无法播放。"))
            return
        }
        let center = NotificationCenter.default
        playbackObservers = [
            center.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: RunLoop.main).sink { _ in onEnd() },
            center.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
                .receive(on: RunLoop.main).sink { note in
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    onFailure(error ?? RecorderError.message("MP4 播放已中断。"))
                },
            center.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
                .receive(on: RunLoop.main).sink { _ in
                    onFailure(RecorderError.message("MP4 播放已中断。"))
                }
        ]
        player.isMuted = !includesAudio
        resume(at: hostTime, elapsed: 0)
    }

    func setPaused(_ paused: Bool, at hostTime: CMTime, elapsed: Double) {
        if paused { player.pause() }
        else { resume(at: hostTime, elapsed: elapsed) }
    }

    private func resume(at hostTime: CMTime, elapsed: Double) {
        let time = videoRange.start + CMTime(seconds: elapsed, preferredTimescale: 600_000)
        player.setRate(1, time: min(time, videoRange.end), atHostTime: hostTime)
    }

    func stopPlayback() {
        playbackObservers.removeAll()
        player.pause()
    }

    func preserveFiles() { preserved = true }

    func close() {
        stopPlayback()
        player.replaceCurrentItem(with: nil)
        if !preserved { try? FileManager.default.removeItem(at: folder) }
    }
}
