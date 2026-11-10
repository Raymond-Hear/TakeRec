import AppKit
import Carbon
import CoreImage
import CoreMedia
import CoreText
import os

private let keyboardLog = Logger(subsystem: "local.takerec.community", category: "KeyboardOverlay")

enum KeyboardDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case shortcuts = "快捷键和操作键"
    case all = "所有按键"

    var id: Self { self }
}

struct KeyboardCaptureOptions: Sendable {
    var mode: KeyboardDisplayMode
    var corner: CameraCorner
    var showInEditorInitially = true
}

enum KeyboardCaptureIssue: Error {
    case inputMonitoring, unavailable

    var recordingNotice: String {
        switch self {
        case .inputMonitoring: "本次未录制按键轨。输入监控未就绪。"
        case .unavailable: "本次未录制按键轨。macOS 未能启动按键采集。"
        }
    }
}

struct RecordedKeyPress: Codable, Equatable, Sendable {
    let time: Double
    let label: String
}

struct KeyboardTrace: Codable, Equatable, Sendable {
    let corner: CameraCorner
    var presses: [RecordedKeyPress] = []
    var clearTimes: [Double]?

    func recentLabels(at time: Double, since clipStart: Double) -> [String] {
        let end = firstPress(atOrAfter: time.nextUp)
        let cutoff = max(clipStart, time - 1.6)
        let clearedAt = clearTimes?.last(where: { $0 <= time }) ?? -.infinity
        return presses[max(0, end - 4)..<end].filter { $0.time >= cutoff && $0.time > clearedAt }.map(\.label)
    }

    func presses(in range: Range<Double>) -> ArraySlice<RecordedKeyPress> {
        presses[firstPress(atOrAfter: range.lowerBound)..<firstPress(atOrAfter: range.upperBound)]
    }

    private func firstPress(atOrAfter time: Double) -> Int {
        var lower = 0
        var upper = presses.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if presses[middle].time < time { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}

private final class KeyboardEventTap {
    private final class Callback: Sendable {
        let receive: @MainActor @Sendable (CGEventType, CGEvent?, CMTime) -> Void

        init(_ receive: @escaping @MainActor @Sendable (CGEventType, CGEvent?, CMTime) -> Void) {
            self.receive = receive
        }
    }

    private let port: CFMachPort
    private let workerLoop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)

    init?(receive: @escaping @MainActor @Sendable (CGEventType, CGEvent?, CMTime) -> Void) {
        let callback = Callback(receive)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                                           callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            if type == .keyDown {
                if !IsSecureEventInputEnabled(), let copy = event.copy() {
                    DispatchQueue.main.async { callback.receive(type, copy, time) }
                }
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { callback.receive(type, nil, time) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(callback).toOpaque()) else { return nil }
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.port = port
        let workerLoop = workerLoop
        let worker = Thread {
            // The run loop owns the callback context until the port has stopped delivering events.
            withExtendedLifetime(callback) {
                let loop = CFRunLoopGetCurrent()!
                workerLoop.withLockUnchecked { $0 = loop }
                CFRunLoopAddSource(loop, source, .defaultMode)
                CFRunLoopRun()
            }
        }
        worker.name = "TakeRec keyboard event tap"
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    var isEnabled: Bool { CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port) }

    func setEnabled(_ enabled: Bool) {
        if CFMachPortIsValid(port) { CGEvent.tapEnable(tap: port, enable: enabled) }
    }

    deinit {
        CFMachPortInvalidate(port)
        if let loop = workerLoop.withLockUnchecked({ $0 }) { CFRunLoopStop(loop) }
    }
}

@MainActor
final class KeyPressCapture {
    private enum ListenerState: String {
        case listening, protectedInput, reconnecting, permissionUnavailable, stoppedBySystem
    }

    private let options: KeyboardCaptureOptions
    private let excludedShortcuts: () -> [ShortcutKey]
    private let onPress: ([String]) -> Void
    private var tap: KeyboardEventTap?
    private var tapID: UUID?
    private var healthCheck: Task<Void, Never>?
    private var listenerState = ListenerState.listening
    private var wasInterrupted = false
    private var epoch: CMTime?
    private var pauses = CapturePauseClock()
    private var trace: KeyboardTrace
    private var received = 0

    init(options: KeyboardCaptureOptions, excludedShortcuts: @escaping () -> [ShortcutKey],
         onPress: @escaping ([String]) -> Void) {
        self.options = options
        self.excludedShortcuts = excludedShortcuts
        self.onPress = onPress
        trace = KeyboardTrace(corner: options.corner)
    }

    func prepare() throws(KeyboardCaptureIssue) {
        guard CGPreflightListenEventAccess() else { throw .inputMonitoring }
        guard installTap() else { throw .unavailable }
    }

    private func installTap() -> Bool {
        let id = UUID()
        guard let tap = KeyboardEventTap(receive: { [weak self] type, event, time in
            guard let self, self.tapID == id else { return }
            self.receive(type, event, at: time)
        }) else { return false }
        tapID = id
        self.tap = tap
        return true
    }

    @discardableResult
    func start(at hostTime: Double) -> Bool {
        guard let tap else { return false }
        epoch = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        tap.setEnabled(true)
        guard tap.isEnabled else { return false }
        checkListener()
        healthCheck = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                guard let self else { return }
                self.checkListener()
            }
        }
        return true
    }

    var waitingDescription: String {
        switch listenerState {
        case .protectedInput: "macOS 正在保护键盘输入"
        case .reconnecting: "正在恢复按键采集"
        case .permissionUnavailable: "输入监控未就绪"
        case .stoppedBySystem: "macOS 已停用按键采集"
        case .listening: options.mode == .all ? "等待按键" : "等待快捷键或操作键"
        }
    }

    var recordingNotice: String? {
        wasInterrupted ? "按键采集曾中断，期间的按键未记录。" : nil
    }

    func setPaused(_ paused: Bool, at time: CMTime) {
        pauses.setPaused(paused, at: time)
        if paused { tap?.setEnabled(false) }
        else { checkListener(tryImmediately: true) }
    }

    func clear(at time: CMTime) {
        guard let epoch else { return }
        if trace.clearTimes == nil { trace.clearTimes = [] }
        trace.clearTimes?.append(pauses.elapsed(since: epoch, at: time))
        onPress([])
    }

    func stop() -> KeyboardTrace {
        if epoch != nil {
            keyboardLog.notice("Received \(self.received) key events; kept \(self.trace.presses.count) key labels")
        }
        epoch = nil
        healthCheck?.cancel()
        healthCheck = nil
        tapID = nil
        tap = nil
        return trace
    }

    private func updateListener(_ state: ListenerState) {
        guard state != listenerState else { return }
        listenerState = state
        if state != .listening {
            wasInterrupted = true
            onPress([])
        }
        keyboardLog.notice("Keyboard listener: \(state.rawValue, privacy: .public)")
    }

    private func checkListener(tryImmediately: Bool = false) {
        guard epoch != nil, pauses.pausedAt == nil, listenerState != .stoppedBySystem else { return }
        if IsSecureEventInputEnabled() {
            updateListener(.protectedInput)
            return
        }
        if tap?.isEnabled == true {
            updateListener(.listening)
            return
        }
        if !tryImmediately && listenerState == .listening {
            // Give macOS a chance to report an explicit disable before attempting recovery.
            updateListener(.reconnecting)
            return
        }
        guard CGPreflightListenEventAccess() else {
            updateListener(.permissionUnavailable)
            return
        }
        tap?.setEnabled(true)
        if tap?.isEnabled != true, installTap() { tap?.setEnabled(true) }
        updateListener(tap?.isEnabled == true ? .listening : .reconnecting)
    }

    private func receive(_ type: CGEventType, _ event: CGEvent?, at timestamp: CMTime) {
        guard let epoch, timestamp >= epoch, let adjusted = pauses.adjusted(timestamp) else { return }
        if type == .tapDisabledByUserInput {
            updateListener(.stoppedBySystem)
            return
        }
        guard listenerState != .stoppedBySystem else { return }
        if type == .tapDisabledByTimeout {
            updateListener(.reconnecting)
            checkListener(tryImmediately: true)
            return
        }
        guard type == .keyDown, let event, !IsSecureEventInputEnabled() else { return }
        received += 1
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let press = ShortcutKey.displayedPress(event, mode: options.mode),
              !excludedShortcuts().contains(press.key) else { return }
        let time = (adjusted - epoch).seconds
        guard time.isFinite, time >= (trace.presses.last?.time ?? 0) else { return }
        trace.presses.append(RecordedKeyPress(time: time, label: press.label))
        let now = pauses.elapsed(since: epoch, at: CMClockGetTime(CMClockGetHostTimeClock()))
        onPress(trace.recentLabels(at: now, since: 0))
    }
}

final class KeyboardArtwork {
    private let cache = NSCache<NSString, CIImage>()

    init() { cache.countLimit = 96 }

    func overlay(labels: [String], corner: CameraCorner, canvas: CGRect) -> CIImage? {
        let badges = labels.compactMap(badge(for:))
        guard let first = badges.first else { return nil }
        let edge = min(canvas.width, canvas.height)
        let height = edge * 0.045
        let gap = height * 0.14
        let margin = edge * 0.032
        let totalBadgeWidth = badges.reduce(0) { $0 + $1.extent.width }
        let totalGap = CGFloat(badges.count - 1) * gap
        let available = max(1, canvas.width - 2 * margin - totalGap)
        let scale = min(height / first.extent.height, available / totalBadgeWidth)
        let rowWidth = totalBadgeWidth * scale + totalGap
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        var x = right ? canvas.maxX - margin - rowWidth : margin
        let y = top ? canvas.maxY - margin - first.extent.height * scale : margin
        var row = CIImage.empty()
        for badge in badges {
            let transformed = badge.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
            row = transformed.composited(over: row)
            x += badge.extent.width * scale + gap
        }
        return row
    }

    private func badge(for raw: String) -> CIImage? {
        let label = String(raw.prefix(16))
        guard !label.isEmpty else { return nil }
        if let existing = cache.object(forKey: label as NSString) { return existing }
        let font = CTFontCreateUIFontForLanguage(.system, 40, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.17, green: 0.12, blue: 0.29, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let size = CGSize(width: ceil(max(80, textWidth + 38)), height: 80)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let base = CGRect(origin: .zero, size: size)
        context.setFillColor(red: 0.25, green: 0.19, blue: 0.40, alpha: 0.95)
        context.addPath(CGPath(roundedRect: base, cornerWidth: 17, cornerHeight: 17, transform: nil))
        context.fillPath()
        context.setFillColor(red: 0.95, green: 0.91, blue: 1, alpha: 0.98)
        context.addPath(CGPath(roundedRect: base.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: 2),
                               cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: (size.width - textWidth) / 2, y: (size.height - ascent + descent) / 2 + 2)
        CTLineDraw(line, context)
        guard let rendered = context.makeImage() else { return nil }
        let image = CIImage(cgImage: rendered)
        cache.setObject(image, forKey: label as NSString)
        return image
    }
}
