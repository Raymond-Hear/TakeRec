#if !TAKEREC_STORE
@preconcurrency import AVFoundation
import ImageIO

// The PCM buffer owns its bytes and is never mutated after decoding.
struct PhoneAudioPacket: @unchecked Sendable {
    let sample: CMSampleBuffer
}

struct PhoneVideoPacket: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// The receiver supplies JPEG frames and mono little-endian PCM. A serial queue owns this clock.
final class PhoneMedia: @unchecked Sendable {
    private var nextAudioTime: CMTime?

    func video(_ base64: String) -> CVPixelBuffer? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (2...1920).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (2...1920).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer, CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let flags = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let color = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                       space: color, bitmapInfo: flags) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    func audio(_ base64: String, rate: Int32, receivedAt: CMTime) -> CMSampleBuffer? {
        guard (16_000...96_000).contains(rate), let data = Data(base64Encoded: base64),
              data.count.isMultiple(of: 2), data.count >= 2, data.count <= 16_384 else { return nil }
        let frames = data.count / 2
        let duration = CMTime(value: Int64(frames), timescale: rate)
        let receivedStart = receivedAt - duration
        let start: CMTime
        if let nextAudioTime, abs((nextAudioTime - receivedStart).seconds) < 0.16 {
            start = nextAudioTime
        } else {
            start = receivedStart
        }
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                       mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                       mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                    formatDescriptionOut: &format) == noErr else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                    blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                    offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                    blockBufferOut: &block) == noErr, let block else { return nil }
        guard data.withUnsafeBytes({ raw in
            guard let bytes = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0,
                                                  dataLength: raw.count) == noErr
        }) else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: start,
                                       decodeTimeStamp: .invalid)
        var frameSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1, sampleSizeArray: &frameSize, sampleBufferOut: &sample) == noErr else { return nil }
        nextAudioTime = start + duration
        return sample
    }
}
#endif
