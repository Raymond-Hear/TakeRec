import Carbon
import SwiftUI

@MainActor
final class FullScreenPreview: ObservableObject {
    @Published private(set) var isPresented = false
    private var host: NSHostingView<FullScreenReview>?

    func show(editor: TakeEditorModel, shortcuts: ShortcutPreferences) {
        guard host == nil, editor.previewReady, let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let review = FullScreenReview(editor: editor, shortcuts: shortcuts) { [weak self] in self?.close() }
        let view = NSHostingView(rootView: review)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        let presentation: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
        guard view.enterFullScreenMode(screen, withOptions: [
            .fullScreenModeAllScreens: false,
            .fullScreenModeApplicationPresentationOptions: presentation.rawValue
        ]) else { return }
        host = view
        view.window?.isExcludedFromWindowsMenu = true
        view.window?.makeKey()
        isPresented = true
    }

    func close() {
        guard let host else { return }
        host.exitFullScreenMode()
        self.host = nil
        isPresented = false
    }
}

private struct FullScreenReview: View {
    @ObservedObject var editor: TakeEditorModel
    @ObservedObject var shortcuts: ShortcutPreferences
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PlayerSurface(player: editor.player).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 16) {
                PreviewTransport(editor: editor, playbackKey: shortcuts[.playback].label,
                                 togglePlayback: editor.togglePlayback)
                Button(action: close) {
                    Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("退出全屏 Esc")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
        .background(ShortcutEventMonitor(handle: handleKey))
    }

    private func handleKey(_ event: NSEvent, _: NSWindow) -> Bool {
        if event.keyCode == kVK_Escape, ShortcutKey.modifiers(for: event) == 0 {
            close()
            return true
        }
        guard shortcuts[.playback].matches(event) else { return false }
        if !event.isARepeat { editor.togglePlayback() }
        return true
    }
}

struct PreviewTransport: View {
    @ObservedObject var editor: TakeEditorModel
    let playbackKey: String
    let togglePlayback: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Image(systemName: editor.playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("\(editor.playing ? "暂停" : "播放") \(playbackKey)")
            .accessibilityLabel(editor.playing ? "暂停" : "播放")
            .disabled(!editor.previewReady)
            Slider(value: Binding(get: { editor.playhead }, set: { editor.seek(to: $0) }), in: 0...editor.duration)
                .accessibilityLabel("时间线播放头")
            Text("\(timelineTime(editor.playhead)) / \(timelineTime(editor.duration))")
                .font(.caption.monospacedDigit())
        }
    }
}
