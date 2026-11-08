import SwiftUI
import Carbon

struct ShortcutSettingsView: View {
    @ObservedObject var preferences: ShortcutPreferences
    @State private var issue: String?
    @State private var awaitingRelease: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("快捷键", systemImage: "keyboard").font(.title2.bold())
            Text("点右侧的按键，再按下新的组合。按 Esc 取消。")
                .font(.callout).foregroundStyle(.secondary)
            section("编辑器内", actions: ShortcutAction.editing)
            section("全局录制与提词器", actions: ShortcutAction.recording)
            HStack(alignment: .firstTextBaseline) {
                Text(issue ?? "修改立即生效，并保存在这台 Mac 上。")
                    .font(.caption).foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("恢复默认") {
                    stopLearning()
                    preferences.reset()
                }
                .disabled(preferences.overrides.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 475)
        .background(ShortcutEventMonitor(handle: capture, onResignKey: stopLearning, capturesKeyUp: true))
        .onDisappear(perform: stopLearning)
    }

    private func section(_ title: String, actions: [ShortcutAction]) -> some View {
        GroupBox {
            VStack(spacing: 5) {
                ForEach(actions) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        let listening = preferences.learning == action && awaitingRelease == nil
                        Button {
                            let wasListening = preferences.learning == action
                            stopLearning()
                            if !wasListening { preferences.learning = action }
                        } label: {
                            Text(listening ? "请按键…" : preferences[action].label)
                                .monospaced().frame(minWidth: 95)
                        }
                        .tint(listening ? .accentColor : nil)
                        .accessibilityLabel("修改\(action.title)快捷键")
                        .accessibilityValue(listening ? "正在等待按键" : preferences[action].label)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
        }
    }

    private func capture(_ event: NSEvent, _: NSWindow) -> Bool {
        guard let action = preferences.learning else { return false }
        if event.type == .keyUp {
            if awaitingRelease == event.keyCode { stopLearning() }
            return true
        }
        if event.isARepeat || awaitingRelease != nil { return true }
        if ShortcutKey.modifiers(for: event) == 0 {
            if event.keyCode == kVK_Escape { stopLearning(); return true }
            if event.keyCode == kVK_Tab { stopLearning(); return false }
        }
        guard let key = ShortcutKey(event: event) else {
            issue = "请使用修饰键加一个按键，或选择空格、删除键、F1–F20。"
            return true
        }
        issue = preferences.assign(key, to: action)
        if issue == nil { awaitingRelease = event.keyCode }
        return true
    }

    private func stopLearning() {
        if preferences.learning != nil { preferences.learning = nil }
        awaitingRelease = nil
        issue = nil
    }
}

struct ShortcutEventMonitor: NSViewRepresentable {
    let handle: (NSEvent, NSWindow) -> Bool
    var onResignKey: (() -> Void)?
    var capturesKeyUp = false

    func makeNSView(context: Context) -> MonitorView { MonitorView(capturesKeyUp: capturesKeyUp) }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
        view.onResignKey = onResignKey
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopMonitoring() }

    final class MonitorView: NSView {
        var handle: ((NSEvent, NSWindow) -> Bool)?
        var onResignKey: (() -> Void)?
        private let eventMask: NSEvent.EventTypeMask
        private var token: Any?

        init(capturesKeyUp: Bool) {
            eventMask = capturesKeyUp ? [.keyDown, .keyUp] : .keyDown
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { stopMonitoring() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window == nil || event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                return self.handle?(event, window) == true ? nil : event
            }
            NotificationCenter.default.addObserver(self, selector: #selector(resignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }

        func stopMonitoring() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func resignedKey() { onResignKey?() }
    }
}
