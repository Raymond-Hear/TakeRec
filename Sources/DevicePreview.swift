import Accelerate
@preconcurrency import AVFoundation
import CoreImage
import Foundation

final class PreviewImageDecoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let limit: CGFloat
    private var last: ContinuousClock.Instant?

    init(limit: CGFloat) { self.limit = limit }

    // One sample queue owns each decoder.
    func frame(_ buffer: CVPixelBuffer, lighting: PortraitLighting = PortraitLighting()) -> CGImage? {
        let now = ContinuousClock.now
        if let last, last.duration(to: now) < .milliseconds(85) { return nil }
        last = now
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, limit / max(image.extent.width, image.extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(lighting.apply(to: reduced), from: reduced.extent.integral)
    }
}

final class DeviceInput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "local.desktake.device-control")
    private let outputQueue: DispatchQueue
    private let media: AVMediaType
    private let videoResolution: VideoResolution
    private let video: @Sendable (CVPixelBuffer) -> Void
    private let level: @Sendable (Double) -> Void
    private let audio: (@Sendable (CMSampleBuffer, CMClock) -> Void)?
    private var currentID: String?
    private var lastLevel: ContinuousClock.Instant?

    init(media: AVMediaType, outputQueue: DispatchQueue, videoResolution: VideoResolution = .hd,
         video: @escaping @Sendable (CVPixelBuffer) -> Void = { _ in },
         level: @escaping @Sendable (Double) -> Void = { _ in },
         audio: (@Sendable (CMSampleBuffer, CMClock) -> Void)? = nil) {
        self.media = media
        self.outputQueue = outputQueue
        self.videoResolution = videoResolution
        self.video = video
        self.level = level
        self.audio = audio
    }

    func select(_ id: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    if id != self.currentID || (id != nil && !self.session.isRunning) {
                        if self.session.isRunning { self.session.stopRunning() }
                        self.currentID = nil
                        try self.configure(id)
                        if id != nil {
                            self.session.startRunning()
                            guard self.session.isRunning else {
                                throw RecorderError.message("设备未启动，请检查连接或权限。")
                            }
                        }
                        self.currentID = id
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure(_ id: String?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        guard let id else { return }

        let devices = media == .video ? CameraSource.devices() : MicrophoneSource.devices()
        guard let device = devices.first(where: { $0.uniqueID == id }) else {
            throw RecorderError.message("所选设备已断开，请重新选择。")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderError.message("无法连接所选设备。")
        }
        session.addInput(input)
        let output: AVCaptureOutput
        if media == .video {
            let camera = AVCaptureVideoDataOutput()
            camera.alwaysDiscardsLateVideoFrames = true
            camera.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            camera.setSampleBufferDelegate(self, queue: outputQueue)
            output = camera
        } else {
            let audio = AVCaptureAudioDataOutput()
            audio.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            audio.setSampleBufferDelegate(self, queue: outputQueue)
            output = audio
        }
        guard session.canAddOutput(output) else {
            throw RecorderError.message("所选设备无法提供媒体样本。")
        }
        session.addOutput(output)
        if media == .video {
            let presets: [AVCaptureSession.Preset] = videoResolution == .uhd
                ? [.hd4K3840x2160, .hd1920x1080, .high] : [.hd1920x1080, .high]
            if let preset = presets.first(where: { session.canSetSessionPreset($0) }) { session.sessionPreset = preset }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if media == .video {
            if let image = sample.imageBuffer { video(image) }
            return
        }
        if let audio {
            audio(sample, session.synchronizationClock ?? CMClockGetHostTimeClock())
            return
        }
        let now = ContinuousClock.now
        if let lastLevel, lastLevel.duration(to: now) < .milliseconds(44) { return }
        lastLevel = now
        level(Self.decibels(sample) ?? Double(connection.audioChannels.map(\.averagePowerLevel).max() ?? -72))
    }

    static func decibels(_ sample: CMSampleBuffer) -> Double? {
        guard let format = sample.formatDescription,
              let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              audio.mFormatID == kAudioFormatLinearPCM else { return nil }

        var length = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: &length, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard length >= MemoryLayout<AudioBufferList>.size else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: length,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retained)
        guard status == noErr else { return nil }

        return withExtendedLifetime(retained) {
            var peak = 0.0
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                let bytes = Int(buffer.mDataByteSize)
                if audio.mFormatFlags & kAudioFormatFlagIsFloat != 0, audio.mBitsPerChannel == 32 {
                    var value: Float = 0
                    vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &value, vDSP_Length(bytes / 4))
                    peak = max(peak, Double(value))
                } else if audio.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, audio.mBitsPerChannel == 16 {
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2)
                    peak = max(peak, Double(samples.map { abs(Int($0)) }.max() ?? 0) / 32_768)
                } else if audio.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0, audio.mBitsPerChannel == 32 {
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: bytes / 4)
                    peak = max(peak, Double(samples.map { abs(Int($0)) }.max() ?? 0) / 2_147_483_648)
                } else {
                    return nil
                }
            }
            return clamp(20 * log10(max(0.000_25, peak)), -72, 0)
        }
    }
}
