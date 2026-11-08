import CoreGraphics
import Foundation

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}

struct MotionEffects: Sendable {
    struct Frame {
        var focus = CGPoint(x: 0.5, y: 0.5)
        var zoom = 1.0
        var blur = 0.0
        var cursor: CGPoint?
        var trail: [CGPoint] = []
        var ripples: [(point: CGPoint, progress: Double)] = []

        func pan(in canvas: CGRect) -> CGAffineTransform {
            CGAffineTransform(
                a: zoom, b: 0, c: 0, d: zoom,
                tx: clamp(canvas.midX - focus.x * canvas.width * zoom, canvas.width * (1 - zoom), 0),
                ty: clamp(canvas.midY - (1 - focus.y) * canvas.height * zoom, canvas.height * (1 - zoom), 0)
            )
        }
    }

    let settings: EffectSettings
    let clicks: [PointerClick]
    private let samples: [PointerSample]

    init(settings: EffectSettings, pointer: PointerTrace) {
        self.settings = settings
        clicks = pointer.clicks.sorted { $0.time < $1.time }
        let smoothing = clamp(settings.smoothing, 0, 0.35)
        var filtered: [PointerSample] = []
        for next in pointer.samples.sorted(by: { $0.time < $1.time }) {
            if smoothing > 0, let last = filtered.last, last.visible, next.visible, next.time - last.time < 0.3 {
                let weight = 1 - exp(-max(0, next.time - last.time) / smoothing)
                filtered.append(PointerSample(time: next.time, x: last.x + (next.x - last.x) * weight,
                                              y: last.y + (next.y - last.y) * weight))
            } else {
                filtered.append(next)
            }
        }
        samples = filtered
    }

    func frame(at time: Double) -> Frame {
        var result = Frame(cursor: cursor(at: time))
        if settings.cursorTrail, let current = result.cursor {
            result.trail = [0.15, 0.10, 0.05].compactMap { delay in
                guard let previous = cursor(at: time - delay),
                      hypot(previous.x - current.x, previous.y - current.y) > 0.003 else { return nil }
                return previous
            }
        }
        let transition = clamp(settings.transition, 0.12, 1.2)
        let hold = clamp(settings.hold, 0.15, 3)
        let duration = transition * 2 + hold
        let recent = indexAfter(clicks, time - max(duration, 0.56), timeOf: \.time)
        let end = indexAfter(clicks, time, timeOf: \.time)
        var strongest = 0.0, movement = 0.0, total = 0.0, x = 0.0, y = 0.0
        for click in clicks[recent..<end] {
            let point = CGPoint(x: clamp(click.x, 0, 1), y: clamp(click.y, 0, 1))
            let elapsed = time - click.time
            if settings.ripple && elapsed < 0.56 {
                result.ripples.append((point, elapsed / 0.56))
            }
            if settings.autoZoom && elapsed < duration {
                let rise = ease(elapsed / transition)
                let fall = 1 - ease((elapsed - transition - hold) / transition)
                let weight = rise * fall
                strongest = max(strongest, weight)
                movement = max(movement, 4 * (rise * (1 - rise) + fall * (1 - fall)))
                let focus = (settings.followPointer && !click.manual ? result.cursor : nil) ?? point
                total += weight
                x += focus.x * weight
                y += focus.y * weight
            }
        }
        if total > 0 {
            result.focus = CGPoint(x: x / total, y: y / total)
            result.zoom = 1 + (clamp(settings.zoom, 1, 3) - 1) * strongest
            result.blur = clamp(settings.blur, 0, 10) * movement * min(1, result.zoom - 1 + strongest)
        }
        return result
    }

    private func cursor(at time: Double) -> CGPoint? {
        let index = indexAfter(samples, time, timeOf: \.time)
        guard index > 0 else { return nil }
        let point = samples[index - 1]
        guard point.visible, time - point.time < 0.30 else { return nil }
        guard index < samples.count, samples[index].visible else { return CGPoint(x: point.x, y: point.y) }
        let next = samples[index]
        let weight = clamp((time - point.time) / max(0.001, next.time - point.time), 0, 1)
        return CGPoint(x: point.x + (next.x - point.x) * weight, y: point.y + (next.y - point.y) * weight)
    }

    private func ease(_ progress: Double) -> Double {
        let t = clamp(progress, 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func indexAfter<T>(_ values: [T], _ time: Double, timeOf: KeyPath<T, Double>) -> Int {
        var left = 0
        var right = values.count
        while left < right {
            let middle = left + (right - left) / 2
            if values[middle][keyPath: timeOf] <= time { left = middle + 1 } else { right = middle }
        }
        return left
    }
}
