import AVFoundation

enum SpeechDucking {
    struct Region: Sendable {
        let start: Double
        var end: Double
    }

    private static let attack = 0.10
    private static let hold = 0.08
    private static let release = 0.34

    static func regions(for clips: [TimelineClip], waveforms: [String: AudioWaveform], boost: Double = 1) -> [Region] {
        let active = clips.flatMap { clip -> [Region] in
            guard let waveform = waveforms[clip.file] else { return [] }
            return activity(in: clip, waveform: waveform, boost: boost)
        }.sorted { $0.start < $1.start }

        var regions: [Region] = []
        for signal in active {
            if let last = regions.last, signal.start <= last.end + attack + hold + release {
                regions[regions.count - 1].end = max(last.end, signal.end)
            } else {
                regions.append(signal)
            }
        }
        return regions
    }

    private static func activity(in clip: TimelineClip, waveform: AudioWaveform, boost: Double) -> [Region] {
        let count = waveform.peaks.count
        guard count > 0, waveform.interval.isFinite, waveform.interval > 0 else { return [] }
        let start = Int(clamp(floor(clip.sourceStart / waveform.interval), 0, Double(count)))
        let end = Int(clamp(ceil(clip.sourceEnd / waveform.interval), 0, Double(count)))
        guard start < end else { return [] }
        let peak = Double(waveform.peaks[start..<end].max() ?? 0) * boost
        guard peak >= 0.006 else { return [] }
        let threshold = Float(clamp(peak * 0.22, 0.006, 0.07) / boost)

        var regions: [Region] = []
        var current: Region?
        var signalLength = 0.0
        for index in start..<end where waveform.peaks[index] >= threshold {
            let bin = Double(index) * waveform.interval
            let from = max(clip.sourceStart, bin) - clip.sourceStart + clip.at
            let to = min(clip.sourceEnd, bin + waveform.interval) - clip.sourceStart + clip.at
            guard to > from else { continue }
            if let last = current, from <= last.end + 0.18 {
                current?.end = to
                signalLength += to - from
            } else {
                if let last = current, signalLength >= 0.06 { regions.append(last) }
                current = Region(start: from, end: to)
                signalLength = to - from
            }
        }
        if let last = current, signalLength >= 0.06 { regions.append(last) }
        return regions
    }

    static func apply(to input: AVMutableAudioMixInputParameters, volume: Float,
                      duration: Double, regions: [Region]) {
        guard volume > 0, !regions.isEmpty else {
            input.setVolume(volume, at: .zero)
            return
        }
        let lowered = volume * 0.25
        var position = 0.0
        func ramp(from start: Double, to end: Double, _ initial: Float, _ final: Float) {
            let from = CMTime(seconds: start, preferredTimescale: 48_000)
            let until = CMTime(seconds: end, preferredTimescale: 48_000)
            guard until > from else { return }
            input.setVolumeRamp(fromStartVolume: initial, toEndVolume: final, timeRange: CMTimeRange(start: from, end: until))
        }
        for region in regions where region.start < duration {
            let start = max(position, region.start - attack)
            let loweredAt = min(duration, region.start)
            let releaseAt = min(duration, region.end + hold)
            let finish = min(duration, releaseAt + release)
            ramp(from: position, to: start, volume, volume)
            ramp(from: start, to: loweredAt, volume, lowered)
            ramp(from: loweredAt, to: releaseAt, lowered, lowered)
            ramp(from: releaseAt, to: finish, lowered, volume)
            position = finish
        }
        ramp(from: position, to: duration, volume, volume)
    }
}
