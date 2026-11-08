import SwiftUI
import Combine

@main
struct TakeRecApp: App {
    @StateObject private var model = RecorderModel()
    @StateObject private var preferences = ShortcutPreferences()
    @NSApplicationDelegateAdaptor(TakeRecDelegate.self) private var delegate

    var body: some Scene {
        Window("简录 · TakeRec", id: "recorder") {
            Group {
                if model.phase == .ready, let editor = model.editor {
                    TakeEditorView(editor: editor, shortcuts: preferences, leave: { _ = model.closeEditor() },
                                   continueRecording: { model.continueRecording() })
                } else {
                    RecorderView(model: model, shortcuts: preferences)
                }
            }
            .onAppear { delegate.attach(to: model, preferences: preferences) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1130, height: 800)
        .defaultPosition(.center)

        Settings { ShortcutSettingsView(preferences: preferences) }

        MenuBarExtra {
            RecorderMenu(model: model, shortcuts: preferences)
        } label: {
            Label("简录", systemImage: model.phase == .recording
                  ? (model.isPaused ? "pause.circle.fill" : "record.circle.fill") : "record.circle")
        }
    }
}

@MainActor
final class TakeRecDelegate: NSObject, NSApplicationDelegate {
    private weak var model: RecorderModel?
    private var shortcuts: RecordingShortcuts?
    private var shortcutUpdates: AnyCancellable?

    func attach(to model: RecorderModel, preferences: ShortcutPreferences) {
        guard self.model !== model else { return }
        self.model = model
        shortcuts = RecordingShortcuts { [weak model] shortcut in
            switch shortcut {
            case .start: model?.startRecording()
            case .stop: model?.stop()
            case .previousPage: model?.turnPromptPage(-1)
            case .nextPage: model?.turnPromptPage(1)
            case .togglePrompt: model?.togglePrompt()
            default: break
            }
        }
        preferences.canRegisterGlobal = { [weak self] key in self?.shortcuts?.canRegister(key) == true }
        shortcutUpdates = Publishers.CombineLatest3(model.$promptVisible.removeDuplicates(), preferences.$overrides,
                                                     preferences.$learning.removeDuplicates()).sink { [weak self, weak model] visible, overrides, learning in
            var desired: [ShortcutAction: ShortcutKey] = [:]
            if learning == nil {
                for action in ShortcutAction.recording where visible || (action != .previousPage && action != .nextPage) {
                    desired[action] = overrides[action] ?? action.defaultKey
                }
            }
            model?.availableShortcuts = self?.shortcuts?.activate(desired) ?? []
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

private struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var shortcuts: ShortcutPreferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.phase == .recording {
            if !model.controlsVisible {
                Text("已录制 \(model.recordingTime)")
                if let level = model.recordingLevels.last {
                    Text("\(model.audioMeterTitle) \(String(format: "%.0f dBFS", level))")
                }
            }
            Button(model.isPaused ? "继续录制" : "暂停录制") { model.togglePause() }
            Button(model.availableShortcuts.contains(.stop) ? "结束录制  \(shortcuts[.stop].label)" : "结束录制") { model.stop() }
            if model.canShowRecordingPanels {
                Divider()
                Button(model.controlsVisible ? "隐藏录制浮条" : "显示录制浮条") { model.toggleRecordingStrip() }
                if !model.teleprompter.pages.isEmpty {
                    Button(model.promptVisible ? "隐藏提词器" : "显示提词器") { model.togglePrompt() }
                }
                Button("找回录制浮窗") { model.recoverRecordingTools() }
            } else if let notice = model.recordingPanelAvailability?.notice {
                Text(notice)
            }
            if model.overlayActive { Text("请关闭系统人物前置") }
            Divider()
        }
        Button("打开简录") {
            model.reveal()
            openWindow(id: "recorder")
        }
        Button("退出简录") { NSApp.terminate(nil) }
    }
}
