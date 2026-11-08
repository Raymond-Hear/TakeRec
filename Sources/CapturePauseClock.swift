import CoreMedia

struct CapturePauseClock {
    private(set) var pausedAt: CMTime?
    private var resumedAt: CMTime?
    private var removed = CMTime.zero

    mutating func setPaused(_ paused: Bool, at time: CMTime) {
        if paused {
            if pausedAt == nil { pausedAt = time }
        } else if let pausedAt {
            removed = removed + max(.zero, time - pausedAt)
            resumedAt = time
            self.pausedAt = nil
        }
    }

    func adjusted(_ time: CMTime) -> CMTime? {
        guard pausedAt == nil, time.isNumeric, resumedAt.map({ time >= $0 }) ?? true else { return nil }
        return time - removed
    }

    func elapsed(since start: CMTime, at now: CMTime) -> Double {
        max(0, ((pausedAt ?? now) - removed - start).seconds)
    }
}
