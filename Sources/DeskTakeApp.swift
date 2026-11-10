import SwiftUI
import Combine

@main
struct TakeRecApp: App {
    @StateObject private var model = RecorderModel()
    @StateObject private var preferences = ShortcutPreferences()
    @NSApplicationDelegateAdaptor(TakeRecDelegate.self) private var delegate

    var body: some Scene {
        Window("简录 · TakeRec", id: "recorder") {
            RecorderWindow(model: model, preferences: preferences, delegate: delegate)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1160, height: 850)
        .defaultPosition(.center)

        Settings { ShortcutSettingsView(preferences: preferences) }
    }
}

private struct RecorderWindow: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var preferences: ShortcutPreferences
    let delegate: TakeRecDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.phase == .ready, let editor = model.editor {
                TakeEditorView(editor: editor, shortcuts: preferences, leave: { _ = model.closeEditor() },
                               continueRecording: { model.continueRecording() })
            } else {
                RecorderView(model: model, shortcuts: preferences)
            }
        }
        .onAppear {
            let openWindow = openWindow
            delegate.attach(to: model, preferences: preferences, showWindow: { openWindow(id: "recorder") })
        }
    }
}

@MainActor
enum TakeRecBrand {
    static let icon: NSImage = {
        let bundle = Bundle.main
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = bundle.url(forResource: name, withExtension: nil), let artwork = NSImage(contentsOf: url) {
            return artwork
        }
        return NSWorkspace.shared.icon(forFile: bundle.bundlePath)
    }()

    static let menuIcon = menuImage()
    static let recordingIcon = menuImage(badge: .systemRed)
    static let pausedIcon = menuImage(badge: .systemOrange)

    private static func menuImage(badge: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        guard let artwork = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            let fallback = icon.copy() as? NSImage ?? NSImage(size: size)
            fallback.size = size
            fallback.isTemplate = false
            return fallback
        }
        context.scaleBy(x: 2, y: 2)
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(origin: .zero, size: size))
        if let badge {
            let ring = CGRect(x: 11, y: 11, width: 7, height: 7)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: ring)
            context.setFillColor(badge.cgColor)
            context.fillEllipse(in: ring.insetBy(dx: 1, dy: 1))
        }
        let image = context.makeImage().map { NSImage(cgImage: $0, size: size) } ?? NSImage(size: size)
        image.isTemplate = false
        return image
    }
}

@MainActor
final class TakeRecDelegate: NSObject, NSApplicationDelegate {
    private weak var model: RecorderModel?
    private var shortcuts: RecordingShortcuts?
    private var shortcutUpdates: AnyCancellable?
    private var statusItem: RecordingStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = TakeRecBrand.icon
    }

    func attach(to model: RecorderModel, preferences: ShortcutPreferences, showWindow: @escaping () -> Void) {
        guard self.model !== model else { return }
        self.model = model
        statusItem = RecordingStatusItem(model: model, showWindow: showWindow)
        shortcuts = RecordingShortcuts { [weak model] shortcut in
            switch shortcut {
            case .start: model?.startRecording()
            case .stop: model?.stop()
            case .previousPage: model?.turnPromptPage(-1)
            case .nextPage: model?.turnPromptPage(1)
            case .togglePrompt: model?.togglePrompt()
            case .togglePromptScroll: model?.togglePromptScrolling()
            case .clearKeyDisplay: model?.clearKeyDisplay()
            default: break
            }
        }
        preferences.canRegisterGlobal = { [weak self] key in self?.shortcuts?.canRegister(key) == true }
        let keyboardActive = Publishers.CombineLatest(model.$phase, model.$isCapturingKeys)
            .map { $0 == .recording && $1 }.removeDuplicates()
        let recordingTools = Publishers.CombineLatest3(model.$promptVisible.removeDuplicates(), keyboardActive,
                                                         model.permissions.$reopening.removeDuplicates())
        shortcutUpdates = Publishers.CombineLatest3(recordingTools, preferences.$overrides,
                                                     preferences.$learning.removeDuplicates()).sink { [weak self, weak model] tools, overrides, learning in
            var desired: [ShortcutAction: ShortcutKey] = [:]
            if learning == nil && !tools.2 {
                for action in ShortcutAction.recording {
                    if action.usesVisiblePrompt && !tools.0 { continue }
                    if action == .clearKeyDisplay && !tools.1 { continue }
                    desired[action] = overrides[action] ?? action.defaultKey
                }
            }
            let active = self?.shortcuts?.activate(desired) ?? []
            model?.availableShortcuts = active
            model?.recordingToolKeys = active.compactMap { desired[$0] }
            model?.activeShortcutLabels = desired.filter { active.contains($0.key) }.mapValues(\.label)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        switch model.phase {
        case .idle, .choosing, .ready:
            guard model.editor != nil else { return .terminateNow }
            model.reveal()
            return model.closeEditor() ? .terminateNow : .terminateCancel
        case .recording:
            model.stop()
            return .terminateCancel
        case .connecting, .starting, .finishing, .opening:
            return .terminateCancel
        }
    }
}

@MainActor
final class RecordingStatusItem: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    private let menu = NSMenu()
    private weak var model: RecorderModel?
    private let showWindow: () -> Void
    private var iconUpdates: AnyCancellable?

    init(model: RecorderModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        iconUpdates = Publishers.CombineLatest(model.$phase, model.$isPaused).sink { [weak self] phase, paused in
            self?.updateIcon(phase: phase, paused: paused)
        }
    }

    private func updateIcon(phase: RecorderModel.Phase, paused: Bool) {
        let button = item.button
        if phase == .recording {
            button?.image = paused ? TakeRecBrand.pausedIcon : TakeRecBrand.recordingIcon
            button?.toolTip = paused ? "简录 · 已暂停" : "简录 · 正在录制"
        } else {
            button?.image = TakeRecBrand.menuIcon
            button?.toolTip = "简录"
        }
        button?.setAccessibilityLabel(button?.toolTip)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        if model.phase == .recording {
            if !model.controlsVisible {
                add("已录制 \(model.recordingTime)")
                if let level = model.recordingLevels.last {
                    add("\(model.audioMeterTitle) \(String(format: "%.0f dBFS", level))")
                }
            }
            add(model.isPaused ? "继续录制" : "暂停录制", #selector(togglePause))
            let stop = model.activeShortcutLabels[.stop].map { "结束录制  \($0)" } ?? "结束录制"
            add(stop, #selector(stopRecording))
            if model.canShowRecordingPanels {
                menu.addItem(.separator())
                add(model.controlsVisible ? "隐藏录制控制条" : "显示录制控制条", #selector(toggleStrip))
                if !model.teleprompter.pages.isEmpty {
                    add(model.promptVisible ? "隐藏提词器" : "显示提词器", #selector(togglePrompt))
                }
                add("找回录制浮窗", #selector(recoverPanels))
            } else if let notice = model.recordingPanelAvailability?.notice {
                add(notice)
            }
            if let issue = model.keyboardCaptureIssue { add(issue.recordingNotice) }
            if model.overlayActive { add("请关闭系统人物前置") }
            menu.addItem(.separator())
        }
        add("打开简录", #selector(openRecorder))
        add("退出简录", #selector(quit))
    }

    private func add(_ title: String, _ action: Selector? = nil) {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        row.isEnabled = action != nil
        menu.addItem(row)
    }

    @objc private func openRecorder() {
        model?.reveal()
        showWindow()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func togglePause() { model?.togglePause() }
    @objc private func stopRecording() { model?.stop() }
    @objc private func toggleStrip() { model?.toggleRecordingStrip() }
    @objc private func togglePrompt() { model?.togglePrompt() }
    @objc private func recoverPanels() { model?.recoverRecordingTools() }
}
