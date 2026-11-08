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

@MainActor
final class TeleprompterScript: ObservableObject {
    @Published var text = "" {
        didSet {
            pages = Self.paginate(text)
            page = 0
        }
    }
    @Published var showOnRecord = true
    @Published var showNavigation = true
    @Published private(set) var pages: [String] = []
    @Published private(set) var page = 0

    var currentText: String { pages.isEmpty ? "" : pages[page] }

    func step(_ delta: Int) {
        guard !pages.isEmpty else { return }
        page = min(max(0, page + delta), pages.count - 1)
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
        let bounds = frame(width: 570, height: 86, atTop: false, displayID: displayID)
        if controls == nil {
            controls = panel(title: "录制浮条", bounds: bounds, content: RecordingStrip(model: model))
        } else if recenter {
            controls?.setFrameOrigin(bounds.origin)
        }
        controls?.orderFrontRegardless()
        return controls?.isVisible == true
    }

    func showPrompt(_ script: TeleprompterScript, displayID: CGDirectDisplayID?, recenter: Bool = false,
                    close: @escaping () -> Void) -> Bool {
        let bounds = frame(width: PromptLayout.width, height: PromptLayout.height, atTop: true, displayID: displayID)
        if prompt == nil {
            prompt = panel(title: "提词器", bounds: bounds, content: TeleprompterPanel(script: script, close: close))
        } else if recenter || (displayID != nil && prompt?.screen?.captureDisplayID != displayID) {
            prompt?.setFrameOrigin(bounds.origin)
        }
        prompt?.orderFrontRegardless()
        return prompt?.isVisible == true
    }

    func hideControls() {
        controls?.orderOut(nil)
        controls?.contentView = nil
        controls = nil
    }

    func hidePrompt() { prompt?.orderOut(nil) }

    func coversQuartzPoint(_ point: CGPoint) -> Bool {
        let location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - point.y)
        return [controls, prompt].compactMap { $0 }.contains { $0.isVisible && $0.frame.contains(location) }
    }

    private func frame(width: CGFloat, height: CGFloat, atTop: Bool, displayID: CGDirectDisplayID?) -> CGRect {
        let display = displayID.flatMap { id in NSScreen.screens.first { $0.captureDisplayID == id } }
        let frame = (display ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        return CGRect(x: frame.midX - width / 2, y: atTop ? frame.maxY - height - 18 : frame.minY + 26,
                      width: width, height: height)
    }

    private func panel<Content: View>(title: String, bounds: CGRect, content: Content) -> NSPanel {
        let panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: content.frame(width: bounds.width, height: bounds.height))
        panel.setFrame(bounds, display: false)
        return panel
    }
}

struct RecordingStrip: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.isPaused ? "已暂停" : "正在录制",
                          systemImage: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.isPaused ? Color.orange : Color(red: 1, green: 0.45, blue: 0.44))
                    Text(model.cameraStatus)
                        .font(.caption2).foregroundStyle(model.cameraStopped ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                .frame(width: 111, alignment: .leading)
                .overlay(alignment: .topLeading) { PanelDragHandle().frame(width: 88, height: 19) }

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
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.13)) }
        .environment(\.colorScheme, .dark)
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
                Text("\(script.page + 1) / \(script.pages.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    script.showNavigation.toggle()
                } label: { Image(systemName: script.showNavigation ? "chevron.up" : "chevron.down") }
                .help(script.showNavigation ? "收起翻页按钮" : "展开翻页按钮")
                .accessibilityLabel(script.showNavigation ? "收起翻页按钮" : "展开翻页按钮")
                Button(action: close) { Image(systemName: "xmark") }
                    .help("隐藏提词器").accessibilityLabel("隐藏提词器")
            }
            .buttonStyle(.borderless)
            ScrollView {
                Text(script.currentText)
                    .font(.system(size: PromptLayout.fontSize, weight: .medium)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
            .defaultScrollAnchor(.top)
            .id(script.page)
            if script.showNavigation {
                HStack(spacing: 8) {
                    Button("‹ 上一页") { script.step(-1) }.disabled(script.page == 0)
                    Button("下一页 ›") { script.step(1) }.disabled(script.page + 1 >= script.pages.count)
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
            Text("\(shortcuts[.previousPage].label) 上一页    \(shortcuts[.nextPage].label) 下一页    \(shortcuts[.togglePrompt].label) 显示或隐藏")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(script.pages.count) 页").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("浮窗预览") {
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
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
