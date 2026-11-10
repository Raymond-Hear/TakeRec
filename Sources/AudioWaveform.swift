import Accelerate
@preconcurrency import AVFoundation

struct AudioWaveform: Sendable {
    let interval: Double
    let peaks: [Float]

    var hasAudibleInput: Bool {
        let activeTime = Double(peaks.filter { $0 >= 0.0056 }.count) * interval
        return activeTime > 0 && activeTime >= min(1, Double(peaks.count) * interval * 0.04)
    }

    func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let first = max(0, Int(floor(start / interval)))
        let last = min(peaks.count - 1, Int(ceil(end / interval)))
        guard first <= last else { return 0 }
        return peaks[first...last].max() ?? 0
    }

    static func read(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return AudioWaveform(interval: 0.02, peaks: [])
        }
        let span = try await track.load(.timeRange)
        let end = span.end.seconds
        guard end.isFinite, end > 0 else { return AudioWaveform(interval: 0.02, peaks: []) }
        let interval = max(0.02, end / 200_000)
        var peaks = [Float](repeating: 0, count: Int(ceil(end / interval)) + 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 24_000
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return AudioWaveform(interval: interval, peaks: []) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.message("无法读取音频波形。") }

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let data = sample.dataBuffer, let format = sample.formatDescription,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  description.pointee.mChannelsPerFrame == 1,
                  description.pointee.mBitsPerChannel == 32,
                  description.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { continue }
            let rate = description.pointee.mSampleRate
            let start = sample.presentationTimeStamp.seconds
            guard start.isFinite, rate > 0 else { continue }
            let bytes = CMBlockBufferGetDataLength(data)
            var pcm = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            guard !pcm.isEmpty else { continue }
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            pcm.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var index = 0
                while index < buffer.count {
                    let time = start + Double(index) / rate
                    let bucket = Int(floor(time / interval))
                    let remaining = max(1, Int(ceil((Double(bucket + 1) * interval - time) * rate)))
                    let count = min(remaining, buffer.count - index)
                    if peaks.indices.contains(bucket) {
                        var value: Float = 0
                        vDSP_maxmgv(base.advanced(by: index), 1, &value, vDSP_Length(count))
                        peaks[bucket] = max(peaks[bucket], min(1, value))
                    }
                    index += count
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? RecorderError.message("音频波形解码中断。") }
        return AudioWaveform(interval: interval, peaks: peaks)
    }
}
