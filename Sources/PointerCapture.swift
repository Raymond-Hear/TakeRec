import AppKit
import CoreMedia
import ScreenCaptureKit

@MainActor
final class PointerCapture {
    private let initialBounds: CGRect
    private let windowID: CGWindowID?
    private let ownerPID: pid_t?
    private let canvas: CGSize
    private let recordsClicks: Bool
    private let coversLocation: (CGPoint) -> Bool
    private var trace = PointerTrace()
    private var epoch = CMTime.zero
    private var pauses = CapturePauseClock()
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(filter: SCContentFilter, size: CaptureSize, recordsClicks: Bool = true, croppedTop: CGFloat = 0,
         coversLocation: @escaping (CGPoint) -> Bool = { _ in false }) {
        canvas = size.dimensions
        self.recordsClicks = recordsClicks
        self.coversLocation = coversLocation
        let window: SCWindow?
        let display: SCDisplay?
        if #available(macOS 15.2, *) {
            window = filter.style == .window ? filter.includedWindows.first : nil
            display = filter.style == .display ? filter.includedDisplays.first : nil
        } else {
            window = nil
            display = nil
        }
        windowID = window?.windowID
        ownerPID = window?.owningApplication?.processID
        let bounds = window?.frame ?? display?.frame ?? filter.contentRect
        initialBounds = CGRect(x: bounds.minX, y: bounds.minY + croppedTop,
                               width: bounds.width, height: bounds.height - croppedTop)
    }

    func start(at hostTime: Double) {
        guard timer == nil else { return }
        epoch = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        if recordsClicks {
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
                MainActor.assumeIsolated { self?.recordClick(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                MainActor.assumeIsolated { self?.recordClick(event) }
                return event
            }
        }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPosition() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        recordPosition()
    }

    func stop() -> PointerTrace {
        timer?.invalidate()
        timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        return trace
    }

    func setPaused(_ paused: Bool, at time: CMTime) {
        pauses.setPaused(paused, at: time)
        if !paused { recordPosition() }
    }

    private func time(for raw: CMTime) -> Double? {
        guard let time = pauses.adjusted(raw), time >= epoch else { return nil }
        return (time - epoch).seconds
    }

    private func normalized(_ location: CGPoint) -> CGPoint? {
        guard !coversLocation(location) else { return nil }
        if let ownerPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != ownerPID { return nil }

        let bounds: CGRect
        if let windowID {
            let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
            guard let description = list?.first,
                  let raw = description[kCGWindowBounds as String] as? [String: Any],
                  let current = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            bounds = current
        } else {
            bounds = initialBounds
        }
        guard bounds.contains(location), bounds.width > 0, bounds.height > 0 else { return nil }

        let factor = min(canvas.width / bounds.width, canvas.height / bounds.height)
        let fitted = CGSize(width: bounds.width * factor, height: bounds.height * factor)
        return CGPoint(x: ((location.x - bounds.minX) * factor + (canvas.width - fitted.width) / 2) / canvas.width,
                       y: ((location.y - bounds.minY) * factor + (canvas.height - fitted.height) / 2) / canvas.height)
    }

    private func recordPosition() {
        guard let time = time(for: CMClockGetTime(CMClockGetHostTimeClock())) else { return }
        let location = quartzPoint(NSEvent.mouseLocation)
        if let position = normalized(location) {
            trace.samples.append(PointerSample(time: time, x: position.x, y: position.y))
        } else if trace.samples.last?.visible != false {
            trace.samples.append(PointerSample(time: time, x: 0, y: 0, visible: false))
        }
    }

    private func recordClick(_ event: NSEvent) {
        let location = event.window.map { quartzPoint($0.convertPoint(toScreen: event.locationInWindow)) }
            ?? event.cgEvent?.location
        let raw = CMTime(seconds: event.timestamp, preferredTimescale: 1_000_000_000)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let time = raw >= epoch && raw <= now + CMTime(value: 50, timescale: 1_000) ? raw : now
        guard let timestamp = self.time(for: time), let location, let point = normalized(location) else { return }
        trace.clicks.append(PointerClick(time: timestamp, x: point.x, y: point.y))
    }

    private func quartzPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - location.y)
    }
}
