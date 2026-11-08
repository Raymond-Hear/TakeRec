import Foundation

struct TimelineClip: Codable, Equatable, Identifiable, Sendable {
    static let minimumLength = 1.0 / 30
    var id = UUID()
    let kind: TrackKind
    let file: String
    let title: String
    let mediaStart: Double
    let mediaEnd: Double
    var sourceStart: Double
    var length: Double
    var at: Double

    var end: Double { at + length }
    var sourceEnd: Double { sourceStart + length }

    func contains(_ time: Double) -> Bool { time >= at && time < end }

    func section(from start: Double, to end: Double) -> Self {
        var clip = self
        clip.sourceStart += start - at
        clip.at = start
        clip.length = end - start
        return clip
    }
}

enum ClipEdit {
    private static let epsilon = 0.00001

    static func split(_ clips: [TimelineClip], at time: Double, kind: TrackKind?) -> ([TimelineClip], UUID?) {
        var selected: UUID?
        let pieces = clips.flatMap { clip -> [TimelineClip] in
            guard kind == nil || kind == clip.kind,
                  time - clip.at >= TimelineClip.minimumLength, clip.end - time >= TimelineClip.minimumLength
            else { return [clip] }
            var right = clip.section(from: time, to: clip.end)
            right.id = UUID()
            if selected == nil || clip.kind == kind || (kind == nil && clip.kind == .screen) { selected = right.id }
            return [clip.section(from: clip.at, to: time), right]
        }
        return (pieces, selected)
    }

    static func moved(_ clip: TimelineClip, to time: Double, among clips: [TimelineClip],
                      playhead: Double, snap: Double) -> TimelineClip {
        let other = lane(excluding: clip, in: clips)
        let edges: [Double] = [0, playhead] + other.flatMap { clip -> [Double] in [clip.at, clip.end] }
        let left = snapped(max(0, time), to: edges + edges.map { $0 - clip.length }, within: snap)
        var best = max(0, left)
        var distance = Double.infinity
        var minimum = 0.0
        for next in other {
            let maximum = next.at - clip.length
            if maximum >= minimum - epsilon {
                let candidate = clamp(left, minimum, max(minimum, maximum))
                if abs(candidate - left) < distance {
                    best = candidate
                    distance = abs(candidate - left)
                }
            }
            minimum = max(minimum, next.end)
        }
        let tail = max(minimum, left)
        if abs(tail - left) < distance { best = tail }
        var result = clip
        result.at = best
        return result
    }

    static func trimmed(_ clip: TimelineClip, left: Bool, to time: Double, among clips: [TimelineClip],
                        playhead: Double, snap: Double) -> TimelineClip {
        let other = lane(excluding: clip, in: clips)
        let minimum = TimelineClip.minimumLength
        var result = clip
        if left {
            let previous = other.last(where: { $0.end <= clip.at + epsilon })?.end ?? 0
            let earliest = max(previous, clip.at - (clip.sourceStart - clip.mediaStart))
            let edge = clamp(snapped(time, to: [previous, playhead], within: snap),
                             earliest, max(earliest, clip.end - minimum))
            result = clip.section(from: edge, to: clip.end)
        } else {
            let next = other.first(where: { $0.at >= clip.end - epsilon })?.at ?? .infinity
            let latest = min(next, clip.at + clip.mediaEnd - clip.sourceStart)
            let edge = clamp(snapped(time, to: [next, playhead], within: snap),
                             min(latest, clip.at + minimum), latest)
            result.length = edge - clip.at
        }
        return result
    }

    static func packed(_ clips: [TimelineClip], kind: TrackKind) -> [TimelineClip] {
        var time = 0.0
        let packed = clips.filter { $0.kind == kind }.sorted { $0.at < $1.at }.map { clip in
            var clip = clip
            clip.at = time
            time = clip.end
            return clip
        }
        return clips.filter { $0.kind != kind } + packed
    }

    static func removeTime(from start: Double, to end: Double, in clips: [TimelineClip]) -> [TimelineClip] {
        guard end > start else { return clips }
        return clips.flatMap { clip -> [TimelineClip] in
            if clip.end <= start { return [clip] }
            if clip.at >= end {
                var moved = clip
                moved.at -= end - start
                return [moved]
            }
            var remaining: [TimelineClip] = []
            if start - clip.at >= TimelineClip.minimumLength {
                remaining.append(clip.section(from: clip.at, to: start))
            }
            if clip.end - end >= TimelineClip.minimumLength {
                var right = clip.section(from: end, to: clip.end)
                right.at = start
                if !remaining.isEmpty { right.id = UUID() }
                remaining.append(right)
            }
            return remaining
        }
    }

    private static func lane(excluding clip: TimelineClip, in clips: [TimelineClip]) -> [TimelineClip] {
        clips.filter { $0.kind == clip.kind && $0.id != clip.id }.sorted { $0.at < $1.at }
    }

    private static func snapped(_ value: Double, to points: [Double], within threshold: Double) -> Double {
        guard let nearest = points.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= threshold else { return value }
        return nearest
    }
}

struct TimelineMarker: Identifiable {
    let clip: TimelineClip
    let click: PointerClick
    var time: Double { clip.at + click.time - clip.sourceStart }
    var id: String { "\(clip.id)-\(click.id)" }
}

extension TakeManifest {
    var timelineMarkers: [TimelineMarker] {
        timelineClips.filter { $0.kind == .screen }.flatMap { clip in
            clicks(in: clip).map { TimelineMarker(clip: clip, click: $0) }
        }.sorted { $0.time < $1.time }
    }

    func clicks(in clip: TimelineClip) -> [PointerClick] {
        let recorded = clip.file == TrackKind.screen.filename ? pointer.clicks : (appendedScreens?[clip.file]?.pointer.clicks ?? [])
        let clicks = recorded + (extraFocus?[clip.file] ?? [])
        return clicks.filter { $0.time >= clip.sourceStart && $0.time < clip.sourceEnd }
    }
}
