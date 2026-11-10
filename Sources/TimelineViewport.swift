import SwiftUI

struct TimelineViewport {
    static let zoomRange = -1.0...1.0
    private static let zoomInStops = 5.0

    let duration: Double
    let width: Double
    let zoom: Double
    let start: Double
    let scale: Double
    let maximumStart: Double

    private var stops: Double { zoom < 0 ? zoom : zoom * Self.zoomInStops }
    var span: Double { width / scale }
    var end: Double { start + span }

    init(duration: Double, width: Double, zoom: Double, start: Double) {
        self.duration = duration
        self.width = max(1, width)
        self.zoom = clamp(zoom, Self.zoomRange.lowerBound, Self.zoomRange.upperBound)
        let zoomStops = self.zoom < 0 ? self.zoom : self.zoom * Self.zoomInStops
        let paddedDuration = duration + max(0.8, duration * 0.10)
        let visibleDuration = paddedDuration / exp2(zoomStops)
        scale = self.width / visibleDuration
        let scrollableEnd = min(paddedDuration, duration + visibleDuration * 0.06)
        maximumStart = max(0, scrollableEnd - visibleDuration)
        self.start = clamp(start, 0, maximumStart)
    }

    func x(at time: Double) -> Double { (time - start) * scale }
    func time(at x: Double) -> Double { start + x / scale }

    func shows(_ clip: TimelineClip) -> Bool { clip.end > start && clip.at < end }

    func zoomed(to value: Double, at x: Double) -> Self {
        let anchor = clamp(x, 0, width)
        let target = Self(duration: duration, width: width, zoom: value, start: 0)
        return Self(duration: duration, width: width, zoom: target.zoom,
                    start: time(at: anchor) - anchor / target.scale)
    }

    func zoomed(by change: Double, at x: Double) -> Self {
        let target = clamp(stops + change, -1, Self.zoomInStops)
        return zoomed(to: target < 0 ? target : target / Self.zoomInStops, at: x)
    }
}

enum TimelineWheelAction: Equatable {
    case zoom(Double), pan(Double), ignore

    init?(x: Double, y: Double, modifiers: NSEvent.ModifierFlags, precise: Bool, momentum: Bool) {
        let keys = modifiers.intersection([.control, .option, .command, .shift])
        let delta = abs(y) >= abs(x) ? y : x
        switch keys {
        case .control:
            self = momentum ? .ignore : .zoom(delta * (precise ? 0.008 : 0.23))
        case .option:
            self = .pan(-delta * (precise ? 1 : 84))
        case [] where abs(x) > abs(y):
            self = .pan(-x * (precise ? 1 : 84))
        default:
            return nil
        }
    }
}

struct TimelineWheelMonitor: NSViewRepresentable {
    let handle: (TimelineWheelAction, Double) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) { view.stopMonitoring() }

    final class WheelView: NSView {
        var handle: ((TimelineWheelAction, Double) -> Void)?
        private var token: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { stopMonitoring() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil, let handle = self.handle else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(point),
                      let action = TimelineWheelAction(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                          modifiers: event.modifierFlags, precise: event.hasPreciseScrollingDeltas,
                          momentum: !event.momentumPhase.isEmpty) else { return event }
                handle(action, point.x)
                return nil
            }
        }

        func stopMonitoring() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }
}
