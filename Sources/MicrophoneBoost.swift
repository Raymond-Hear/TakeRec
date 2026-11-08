import AudioToolbox
import MediaToolbox

enum MicrophoneBoost {
    private final class State {
        let gain: Float
        var format: AudioStreamBasicDescription?

        init(gain: Double) { self.gain = Float(gain) }
    }

    static func makeTap(gain: Double) throws -> MTAudioProcessingTap {
        let state = State(gain: gain)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(state).toOpaque(),
            init: { _, info, storage in
                if let info { storage.pointee = Unmanaged<State>.fromOpaque(info).retain().toOpaque() }
            },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, list, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut)
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard let format = state.format, format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
                for buffer in UnsafeMutableAudioBufferListPointer(list) {
                    guard let data = buffer.mData else { continue }
                    let samples = framesOut.pointee * Int(buffer.mNumberChannels)
                    let bytes = Int(buffer.mDataByteSize)
                    if format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                        let pcm = data.assumingMemoryBound(to: Float.self)
                        for index in 0..<min(samples, bytes / 4) {
                            pcm[index] = MicrophoneBoost.boosted(pcm[index], by: state.gain)
                        }
                    } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
                        switch format.mBitsPerChannel {
                        case 16:
                            MicrophoneBoost.scaleIntegers(data.assumingMemoryBound(to: Int16.self), min(samples, bytes / 2), by: state.gain)
                        case 32:
                            MicrophoneBoost.scaleIntegers(data.assumingMemoryBound(to: Int32.self), min(samples, bytes / 4), by: state.gain)
                        default: break
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = withExtendedLifetime(state) {
            MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        }
        guard status == noErr, let tap else { throw RecorderError.message("无法启用麦克风增强。") }
        return tap
    }

    private static func scaleIntegers<Sample: FixedWidthInteger & SignedInteger>(
        _ pcm: UnsafeMutablePointer<Sample>, _ count: Int, by gain: Float
    ) {
        let scale = Float(Sample.max)
        for index in 0..<count { pcm[index] = Sample(boosted(Float(pcm[index]) / scale, by: gain) * scale) }
    }

    private static func boosted(_ sample: Float, by gain: Float) -> Float {
        let value = sample * gain
        let magnitude = abs(value)
        let knee: Float = 0.82
        guard magnitude > knee else { return value }
        // Keep normal speech linear and compress only peaks close to full scale.
        let excess = magnitude - knee
        let limited = knee + 0.15 * (excess / (excess + 0.15))
        return value >= 0 ? limited : -limited
    }
}
