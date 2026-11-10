import AppKit
import SwiftUI

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private enum PromptLayout {
    static let width: CGFloat = 530
    static let height: CGFloat = 232
    static let padding: CGFloat = 13
    static let fontSize: CGFloat = 22
    static let linesPerPage = 4
}

enum PromptMode: String, CaseIterable, Identifiable {
    case pages = "手动翻页"
    case scroll = "自动滚动"

    var id: Self { self }
}

struct PromptMovement: Equatable {
    let id = UUID()
    var pages = 0
}

@MainActor
final class TeleprompterScript: ObservableObject {
    @Published var text = "" {
        didSet {
            pages = Self.paginate(text)
            restart()
        }
    }
    @Published var showOnRecord = true
    @Published var showNavigation = true
    @Published var mode = PromptMode(rawValue: UserDefaults.standard.string(forKey: "TakeRec.PromptMode") ?? "") ?? .pages {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "TakeRec.PromptMode")
            restart()
        }
    }
    @Published var speed = (UserDefaults.standard.object(forKey: "TakeRec.PromptSpeed") as? Double)
        .map { min(max($0, 0.5), 3) } ?? 1 {
        didSet { UserDefaults.standard.set(speed, forKey: "TakeRec.PromptSpeed") }
    }
    @Published var panelVisible = false
    @Published var recordingPaused = false
    @Published private(set) var scrollPaused = false
    @Published private(set) var movement = PromptMovement()
    @Published private(set) var pages: [String] = []
    @Published private(set) var page = 0

    var currentText: String { pages.isEmpty ? "" : pages[page] }
    var speedLabel: String { speed.formatted(.number.precision(.fractionLength(0...2))) + "×" }
    var isScrolling: Bool { panelVisible && !recordingPaused && !scrollPaused }

    func restart() {
        page = 0
        scrollPaused = false
        movement = PromptMovement()
    }

    func toggleScrolling() {
        guard mode == .scroll else { return }
        scrollPaused.toggle()
    }

    func step(_ delta: Int) {
        guard !pages.isEmpty else { return }
        if mode == .scroll {
            movement = PromptMovement(pages: delta)
        } else {
            page = min(max(0, page + delta), pages.count - 1)
        }
    }

    static func paginate(_ text: String) -> [String] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.flatMap { block in
            wrap(block.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func wrap(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: PromptLayout.fontSize, weight: .medium)])
        let layout = NSLayoutManager()
        let width = PromptLayout.width - 2 * PromptLayout.padding - 16
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        var pages: [String] = []
        var start = 0
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            lines += 1
            let end = NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            if lines == PromptLayout.linesPerPage || end == storage.length {
                let range = NSRange(location: start, length: end - start)
                let page = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !page.isEmpty { pages.append(page) }
                start = end
                lines = 0
            }
        }
        return pages
    }
}

@MainActor
final class RecordingPanels {
    private var controls: NSPanel?
    private var lastControlsPosition: (origin: CGPoint, displayID: CGDirectDisplayID?)?
    private var prompt: NSPanel?
    private var parkedWindows: [NSWindow] = []

    func parkSetupWindows() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        parkedWindows = NSApp.orderedWindows.filter { $0.isVisible && $0.canHide && $0.level == .normal }
        for window in parkedWindows { window.orderOut(nil) }
    }

    func restoreSetupWindows() {
        let windows = parkedWindows
        parkedWindows.removeAll()
        for window in windows.reversed() { window.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func showControls(for model: RecorderModel, displayID: CGDirectDisplayID?, recenter: Bool = false) -> Bool {
        let strip = controlsPanel(for: model, displayID: displayID, recenter: recenter)
        return show(strip)
    }

    func showPrompt(_ script: TeleprompterScript, displayID: CGDirectDisplayID?, recenter: Bool = false,
                    close: @escaping () -> Void) -> Bool {
        show(promptPanel(for: script, displayID: displayID, recenter: recenter, close: close))
    }

    func prepareForDisplayCapture(_ model: RecorderModel, displayID: CGDirectDisplayID?) throws -> Set<CGWindowID> {
        var panels = [controlsPanel(for: model, displayID: displayID, recenter: false)]
        if !model.teleprompter.pages.isEmpty {
            panels.append(promptPanel(for: model.teleprompter, displayID: displayID, recenter: false) { [weak model] in
                model?.hidePrompt()
            })
        }
        // Register these exact windows with WindowServer before creating the recording filter.
        for panel in panels {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        let ids = Set(panels.compactMap { CGWindowID(exactly: $0.windowNumber) })
        guard ids.count == panels.count, !ids.contains(0) else {
            throw RecorderError.message("无法准备录制浮窗。")
        }
        return ids
    }

    private func controlsPanel(for model: RecorderModel, displayID: CGDirectDisplayID?, recenter: Bool) -> NSPanel {
        let height: CGFloat = model.retainKeystrokes && model.showKeystrokes ? 132 : 102
        let saved = lastControlsPosition.flatMap { $0.displayID == displayID && !recenter ? $0.origin : nil }
        let bounds = frame(width: 570, height: height, atTop: false, displayID: displayID, origin: saved)
        let strip = controls ?? panel(title: "录制控制条", bounds: bounds, content: RecordingStrip(model: model))
        controls = strip
        if recenter { strip.setFrameOrigin(bounds.origin) }
        return strip
    }

    private func promptPanel(for script: TeleprompterScript, displayID: CGDirectDisplayID?, recenter: Bool,
                             close: @escaping () -> Void) -> NSPanel {
        let bounds = frame(width: PromptLayout.width, height: PromptLayout.height, atTop: true, displayID: displayID)
        let prompter = prompt ?? panel(title: "提词器", bounds: bounds, content: TeleprompterPanel(script: script, close: close))
        prompt = prompter
        if recenter || (displayID != nil && prompter.screen?.captureDisplayID != displayID) {
            prompter.setFrameOrigin(bounds.origin)
        }
        return prompter
    }

    private func show(_ panel: NSPanel) -> Bool {
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        return panel.isVisible
    }

    func hideControls(release: Bool = false) {
        if let controls, controls.isVisible, controls.alphaValue > 0 {
            lastControlsPosition = (controls.frame.origin, controls.screen?.captureDisplayID)
        }
        controls?.orderOut(nil)
        if release {
            controls?.contentView = nil
            controls = nil
        }
    }

    func hidePrompt() { prompt?.orderOut(nil) }

    func coversQuartzPoint(_ point: CGPoint) -> Bool {
        let location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - point.y)
        return [controls, prompt].compactMap { $0 }.contains { $0.isVisible && $0.alphaValue > 0 && $0.frame.contains(location) }
    }

    private func frame(width: CGFloat, height: CGFloat, atTop: Bool, displayID: CGDirectDisplayID?,
                       origin: CGPoint? = nil) -> CGRect {
        let display = displayID.flatMap { id in NSScreen.screens.first { $0.captureDisplayID == id } }
        let frame = (display ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let x = origin.map { min(max($0.x, frame.minX), max(frame.minX, frame.maxX - width)) } ?? (frame.midX - width / 2)
        let defaultY = atTop ? frame.maxY - height - 18 : frame.minY + 26
        let y = origin.map { min(max($0.y, frame.minY), max(frame.minY, frame.maxY - height)) } ?? defaultY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func panel<Content: View>(title: String, bounds: CGRect, content: Content) -> NSPanel {
        let panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.isMovable = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = FloatingPanelContent(rootView: content.frame(width: bounds.width, height: bounds.height))
        panel.setFrame(bounds, display: false)
        return panel
    }
}

private final class FloatingPanelContent<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct RecordingStrip: View {
    @ObservedObject var model: RecorderModel

    private let shortcuts: [(ShortcutAction, String)] = [
        (.stop, "结束"), (.previousPage, "向前"), (.nextPage, "向后"), (.togglePromptScroll, "停／继续滚动"),
        (.togglePrompt, "显隐提词"), (.clearKeyDisplay, "清空键帽")
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 5) {
                mainControls.frame(height: 58)
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                shortcutGuide.frame(height: 20)
                if model.retainKeystrokes && model.showKeystrokes { keyPreview.frame(height: 23) }
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.13)).allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
    }

    private var shortcutGuide: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary).accessibilityHidden(true)
            ForEach(shortcuts, id: \.0) { action, title in
                if let key = model.activeShortcutLabels[action] {
                    Text("\(key) \(title)").lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityLabel("录制快捷键")
    }

    private var keyPreview: some View {
        HStack(spacing: 7) {
            Text("实时按键").font(.caption2).foregroundStyle(.secondary)
            if model.visibleKeyLabels.isEmpty {
                Text(model.keyboardWaitingDescription)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.visibleKeyLabels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption.weight(.semibold).monospaced()).lineLimit(1)
                    .foregroundStyle(Color(red: 0.17, green: 0.12, blue: 0.29))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(red: 0.95, green: 0.91, blue: 1), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
    }

    private var mainControls: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("录制控制条", systemImage: "line.3.horizontal")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Label(model.isPaused ? "已暂停" : "正在录制",
                          systemImage: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.isPaused ? Color.orange : Color(red: 1, green: 0.45, blue: 0.44))
                    Text(model.cameraStatus)
                        .font(.caption2).foregroundStyle(model.cameraStopped ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .frame(width: 111, alignment: .leading)
                .overlay { PanelDragHandle() }
                .help("按住这里拖动录制控制条")

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(model.audioMeterTitle).lineLimit(1)
                        Spacer(minLength: 2)
                        if let db = model.recordingLevels.last, !model.isPaused {
                            Text(String(format: "%.0f dBFS", db)).monospacedDigit()
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    AudioLevelBars(levels: model.recordingLevels)
                        .frame(height: 18)
                        .padding(.horizontal, 5)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .opacity(model.isPaused ? 0.4 : 1)
                    if let warning = model.audioWarning {
                        Text(warning).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                Text(model.recordingTime)
                    .font(.system(.headline, design: .monospaced)).lineLimit(1).fixedSize()
                    .accessibilityLabel("已录制 \(model.recordingTime)")

                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "继续" : "暂停", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                Button { model.stop() } label: { Label("结束", systemImage: "stop.fill") }
                    .buttonStyle(DeskPrimaryButton(color: Color(red: 0.74, green: 0.18, blue: 0.20)))
                    .fixedSize()
            }
    }
}

struct TeleprompterPanel: View {
    @ObservedObject var script: TeleprompterScript
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").font(.caption)
                    Text("提词器").font(.caption.weight(.semibold))
                    Spacer()
                }
                .overlay { PanelDragHandle() }
                Text(script.mode == .scroll ? script.speedLabel : "\(script.page + 1) / \(script.pages.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    script.showNavigation.toggle()
                } label: { Image(systemName: script.showNavigation ? "chevron.up" : "chevron.down") }
                .help(script.showNavigation ? "收起提词控制" : "展开提词控制")
                .accessibilityLabel(script.showNavigation ? "收起提词控制" : "展开提词控制")
                Button(action: close) { Image(systemName: "xmark") }
                    .help("隐藏提词器").accessibilityLabel("隐藏提词器")
            }
            .buttonStyle(.borderless)
            if script.mode == .scroll {
                AutomaticPrompt(text: script.text, speed: script.speed, playing: script.isScrolling, movement: script.movement)
            } else {
                ScrollView {
                    Text(script.currentText)
                        .font(.system(size: PromptLayout.fontSize, weight: .medium)).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                }
                .defaultScrollAnchor(.top)
                .id(script.page)
            }
            if script.showNavigation {
                HStack(spacing: 8) {
                    if script.mode == .scroll {
                        Button(script.scrollPaused ? "继续滚动" : "暂停滚动") { script.toggleScrolling() }
                        Button("向上跳一屏") { script.step(-1) }
                        Button("向下跳一屏") { script.step(1) }
                    } else {
                        Button("‹ 上一页") { script.step(-1) }.disabled(script.page == 0)
                        Button("下一页 ›") { script.step(1) }.disabled(script.page + 1 >= script.pages.count)
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(PromptLayout.padding)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.16)) }
        .environment(\.colorScheme, .dark)
    }
}

private struct AutomaticPrompt: NSViewRepresentable {
    let text: String
    let speed: Double
    let playing: Bool
    let movement: PromptMovement

    func makeCoordinator() -> Scroller { Scroller() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.drawsBackground = false
            view.isEditable = false
            view.isSelectable = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
        }
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let scroller = context.coordinator
        if view.string != text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: PromptLayout.fontSize, weight: .medium),
                .foregroundColor: NSColor.white, .paragraphStyle: paragraph
            ]))
        }
        if scroller.movementID != movement.id {
            scroller.movementID = movement.id
            let bounds = scroll.contentView.bounds
            scroller.move(to: movement.pages == 0 ? 0 : bounds.minY + CGFloat(movement.pages) * bounds.height * 0.9)
        }
        scroller.speed = speed
        scroller.setPlaying(playing)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Scroller) {
        coordinator.setPlaying(false)
    }

    final class Scroller {
        weak var scroll: NSScrollView?
        var speed = 1.0
        var movementID: UUID?
        private var timer: Timer?
        private var tickTime = 0.0
        private var fraction: CGFloat = 0

        func setPlaying(_ playing: Bool) {
            if playing, timer == nil {
                tickTime = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if !playing {
                timer?.invalidate()
                timer = nil
            }
        }

        func move(to y: CGFloat) {
            guard let scroll, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: 0, y: min(max(0, y), max(0, document.frame.height - clip.bounds.height))))
            scroll.reflectScrolledClipView(clip)
            fraction = 0
        }

        private func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(0.1, now - tickTime)
            tickTime = now
            guard let scroll, scroll.window?.isVisible == true else { return }
            let distance = fraction + elapsed * speed * 12
            guard distance >= 0.5 else { fraction = distance; return }
            let step = floor(distance * 2) / 2
            move(to: scroll.contentView.bounds.minY + step)
            fraction = distance - step
        }
    }
}

struct TeleprompterSettings: View {
    @ObservedObject var script: TeleprompterScript
    @ObservedObject var shortcuts: ShortcutPreferences
    let preview: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提词器").font(.title2.bold())
            Text("粘贴或输入逐字稿。空行分段，长段落会自动分页。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $script.text)
                .font(.system(size: 15)).padding(8)
                .frame(minHeight: 220)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary) }
                .accessibilityLabel("逐字稿")
            Toggle("开录时显示提词器", isOn: $script.showOnRecord)
            Picker("提词方式", selection: $script.mode) {
                ForEach(PromptMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if script.mode == .scroll {
                HStack {
                    Slider(value: $script.speed, in: 0.5...3, step: 0.25) { Text("滚动速度") }
                    Text(script.speedLabel).font(.callout.monospacedDigit()).frame(width: 54, alignment: .trailing)
                }
                Text("\(shortcuts[.togglePromptScroll].label) 暂停或继续滚动")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(shortcuts[.previousPage].label) 向前    \(shortcuts[.nextPage].label) 向后    \(shortcuts[.togglePrompt].label) 显示或隐藏")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(script.pages.count) 页").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("浮窗预览") {
                    script.restart()
                    dismiss()
                    preview()
                }
                .disabled(script.pages.isEmpty)
                Button("完成") { dismiss() }.buttonStyle(DeskPrimaryButton())
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}

    final class Handle: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window?.performDrag(with: event)
        }
    }
}
