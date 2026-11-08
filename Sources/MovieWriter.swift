@preconcurrency import AVFoundation
import CoreImage
import Foundation

private final class TrackWriter: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let pixels: AVAssetWriterInputPixelBufferAdaptor?
    let size: CaptureSize?
    var hasSamples = false
    var lastAudioTime: CMTime?
    var lastAudioEnd: CMTime?
    var resumeAfter: CMTime?
    var sourceOffset = 0.0

    init(kind: TrackKind, folder: URL, size: CaptureSize? = nil) throws {
        self.size = size
        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent(kind.filename),
                                   fileType: size == nil ? .m4a : .mp4)
        if let size {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(1_000_000, size.width * size.height * 4),
                    AVVideoExpectedSourceFrameRateKey: CaptureSize.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: CaptureSize.framesPerSecond * 2
                ]
            ])
            pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        } else {
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: kind == .system ? 2 : 1,
                AVEncoderBitRateKey: kind == .system ? 160_000 : 96_000
            ])
            pixels = nil
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.message("无法为\(kind.title)配置编码器。")
        }
        writer.add(input)
    }

    func start(at time: CMTime) throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.message("无法开始写入素材。")
        }
        writer.startSession(atSourceTime: time)
    }
}

/// Capture callbacks, frame timing, and track writers share one serial queue.
final class MovieWriter: @unchecked Sendable {
    let queue: DispatchQueue

    private let folder: URL
    private let expected: [TrackKind]
    private let cameraResolution: VideoResolution
    private let meterSource: TrackKind?
    private var tracks: [TrackKind: TrackWriter] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var screen: CVPixelBuffer?
    private var screenMissingSince: ContinuousClock.Instant?
    private var camera: (buffer: CVPixelBuffer, received: ContinuousClock.Instant)?
    private var cameraStopped = false
    private var clock = CMClockGetHostTimeClock()
    private var timer: DispatchSourceTimer?
    private var startTime: CMTime?
    private var hostStart = 0.0
    private var lastFrameIndex: Int64 = -1
    private var failure: Error?
    private var pauses = CapturePauseClock()
    private var lastMeterUpdate: ContinuousClock.Instant?
    private var onLevel: (@Sendable (Double) -> Void)?

    init(folder: URL, size: CaptureSize, options: CaptureOptions,
         queue: DispatchQueue = DispatchQueue(label: "local.desktake.samples", qos: .userInitiated)) throws {
        self.folder = folder
        self.queue = queue
        cameraResolution = options.cameraResolution
        var expected: [TrackKind] = [.screen]
        if options.cameraID != nil { expected.append(.camera) }
        if options.systemAudio { expected.append(.system) }
        if options.microphone { expected.append(.microphone) }
        self.expected = expected
        meterSource = options.microphone ? .microphone : (options.systemAudio ? .system : nil)
        tracks[.screen] = try TrackWriter(kind: .screen, folder: folder, size: size)
        for kind in expected where !kind.isVideo {
            tracks[kind] = try TrackWriter(kind: kind, folder: folder)
        }
    }

    func receiveScreen(_ buffer: CVPixelBuffer?) {
        dispatchPrecondition(condition: .onQueue(queue))
        screen = buffer
        screenMissingSince = buffer == nil ? (screenMissingSince ?? .now) : nil
    }

    func receiveCamera(_ buffer: CVPixelBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !cameraStopped else { return }
        camera = (buffer, .now)
    }

    func setPaused(_ paused: Bool, at hostTime: CMTime) {
        queue.async {
            guard self.timer != nil, self.lastFrameIndex >= 0 else { return }
            let time = CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: self.clock)
            guard time.isNumeric else { return }
            if !paused, self.pauses.pausedAt != nil {
                for (kind, track) in self.tracks where !kind.isVideo { track.resumeAfter = track.lastAudioEnd }
            }
            self.pauses.setPaused(paused, at: time)
        }
    }

    func receiveAudio(_ sample: CMSampleBuffer, source: TrackKind, inputClock: CMClock? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timer != nil, let startTime, let track = tracks[source],
              CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        let inputTime = sample.presentationTimeStamp
        let captureTime = inputClock.map { CMSyncConvertTime(inputTime, from: $0, to: clock) } ?? inputTime
        guard let time = pauses.adjusted(captureTime), time >= startTime,
              track.resumeAfter.map({ time >= $0 - CMTime(value: 1, timescale: 48_000) }) ?? true,
              track.lastAudioTime.map({ time > $0 }) ?? true else { return }
        let aligned: CMSampleBuffer
        if time != inputTime {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return }
            timing.presentationTimeStamp = time
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            aligned = copy
        } else {
            aligned = sample
        }
        if track.writer.status == .unknown {
            do {
                try track.start(at: time)
                track.sourceOffset = (time - startTime).seconds
            } catch {
                failure = error
                return
            }
        }
        guard track.input.isReadyForMoreMediaData else { return }
        if track.input.append(aligned) {
            track.resumeAfter = nil
            track.lastAudioTime = time
            let duration = aligned.duration
            track.lastAudioEnd = duration.isNumeric && duration > .zero ? time + duration : nil
            track.hasSamples = true
            updateMeter(from: sample, source: source)
        } else {
            failure = track.writer.error ?? RecorderError.message("无法写入\(source.title)。")
        }
    }

    private func updateMeter(from sample: CMSampleBuffer, source: TrackKind) {
        guard source == meterSource, let onLevel else { return }
        let now = ContinuousClock.now
        if let lastMeterUpdate, lastMeterUpdate.duration(to: now) < .milliseconds(44) { return }
        lastMeterUpdate = now
        onLevel(DeviceInput.decibels(sample) ?? -72)
    }

    func begin(
        clock: CMClock?,
        onStarted: @escaping @Sendable (Double) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void,
        onLevel: (@Sendable (Double) -> Void)? = nil,
        onCameraStopped: @escaping @Sendable () -> Void = {}
    ) {
        queue.async {
            self.clock = clock ?? CMClockGetHostTimeClock()
            self.onLevel = onLevel
            let waiting = ContinuousClock.now
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(CaptureSize.framesPerSecond)),
                           leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    if let failure = self.failure { throw failure }
                    if let failed = self.tracks.values.first(where: { $0.writer.status == .failed }) {
                        throw failed.writer.error ?? RecorderError.message("写入素材中断。")
                    }
                    if try self.writeFrame() { onStarted(self.hostStart) }
                    if self.lastFrameIndex < 0, waiting.duration(to: .now) > .seconds(8) {
                        let missing = self.screen == nil ? "屏幕" : "摄像头"
                        throw RecorderError.message("未收到\(missing)画面，请检查来源。")
                    }
                    if self.lastFrameIndex >= 0 {
                        if let since = self.screenMissingSince, since.duration(to: .now) > .seconds(4) {
                            throw RecorderError.message("屏幕画面已中断，已结束录制。")
                        }
                        if let camera = self.camera, camera.received.duration(to: .now) > .seconds(4) {
                            self.cameraStopped = true
                            self.camera = nil
                            onCameraStopped()
                        }
                    }
                } catch {
                    self.timer?.cancel()
                    self.timer = nil
                    onFailure(error)
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func writeFrame() throws -> Bool {
        guard let screen, let screenTrack = tracks[.screen],
              pauses.pausedAt == nil else { return false }
        let liveCamera = camera.flatMap { $0.received.duration(to: .now) < .seconds(1) ? $0.buffer : nil }
        if startTime == nil {
            if expected.contains(.camera) {
                guard let liveCamera else { return false }
                let source = CGSize(width: CVPixelBufferGetWidth(liveCamera), height: CVPixelBufferGetHeight(liveCamera))
                let size = try cameraResolution.size(for: source)
                tracks[.camera] = try TrackWriter(kind: .camera, folder: folder, size: size)
            }
            let time = CMClockGetTime(clock)
            let host = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
            hostStart = host.isNumeric ? host.seconds : CMClockGetTime(CMClockGetHostTimeClock()).seconds
            for (kind, track) in tracks where kind.isVideo { try track.start(at: time) }
            startTime = time
        }
        guard let startTime, let now = pauses.adjusted(CMClockGetTime(clock)),
              screenTrack.input.isReadyForMoreMediaData else { return false }
        let elapsed = now - startTime
        let index = lastFrameIndex < 0 ? 0 : CMTimeConvertScale(elapsed, timescale: CaptureSize.framesPerSecond,
                                                               method: .roundTowardZero).value
        guard index > lastFrameIndex else { return false }

        let time = startTime + CMTime(value: index, timescale: CaptureSize.framesPerSecond)
        try append(screen, to: screenTrack, at: time)
        if let liveCamera, let cameraTrack = tracks[.camera], cameraTrack.input.isReadyForMoreMediaData {
            try append(liveCamera, to: cameraTrack, at: time)
        }
        let firstFrame = lastFrameIndex < 0
        lastFrameIndex = index
        return firstFrame
    }

    private func append(_ source: CVPixelBuffer, to track: TrackWriter, at time: CMTime) throws {
        guard let pixels = track.pixels, let size = track.size else { return }
        let buffer: CVPixelBuffer
        if CVPixelBufferGetWidth(source) == size.width, CVPixelBufferGetHeight(source) == size.height {
            buffer = source
        } else {
            var resized: CVPixelBuffer?
            guard let pool = pixels.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &resized) == kCVReturnSuccess,
                  let resized else { throw RecorderError.message("无法分配视频帧。") }
            let image = CIImage(cvPixelBuffer: source)
            let scale = CGAffineTransform(scaleX: CGFloat(size.width) / image.extent.width,
                                          y: CGFloat(size.height) / image.extent.height)
            context.render(image.transformed(by: scale), to: resized, bounds: CGRect(origin: .zero, size: size.dimensions),
                           colorSpace: colorSpace)
            buffer = resized
        }
        guard pixels.append(buffer, withPresentationTime: time) else {
            throw track.writer.error ?? RecorderError.message("写入视频帧时发生错误。")
        }
        track.hasSamples = true
    }

    func finish() async throws -> RecordedMedia {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.screen = nil
                self.camera = nil
                let group = DispatchGroup()
                let tracks = self.tracks
                for track in tracks.values where track.writer.status == .writing {
                    if track.hasSamples {
                        track.input.markAsFinished()
                        group.enter()
                        track.writer.finishWriting { group.leave() }
                    } else {
                        track.writer.cancelWriting()
                    }
                }
                group.notify(queue: self.queue) {
                    let available = self.expected.filter { tracks[$0]?.writer.status == .completed }
                    guard available.first == .screen else {
                        let error = self.failure ?? tracks[.screen]?.writer.error
                            ?? RecorderError.message("没有录到可保存的屏幕画面。")
                        continuation.resume(throwing: error)
                        return
                    }
                    let missing = self.expected.filter { !available.contains($0) }
                    let offsets = Dictionary(uniqueKeysWithValues: available.compactMap { kind -> (TrackKind, Double)? in
                        guard let track = tracks[kind], track.sourceOffset > 0 else { return nil }
                        return (kind, track.sourceOffset)
                    })
                    continuation.resume(returning: RecordedMedia(folder: self.folder, tracks: available, missing: missing,
                                                                 sourceOffsets: offsets, cameraInterrupted: self.cameraStopped))
                }
            }
        }
    }
}
