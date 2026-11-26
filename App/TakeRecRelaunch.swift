import AppKit
import os

@main
@MainActor
struct TakeRecRelaunch {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let originalPID = pid_t(CommandLine.arguments[1]), originalPID > 1 else { return }
        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL) else { return }
        let log = Logger(subsystem: bundle.bundleIdentifier ?? "local.lingfeng.DeskTake", category: "PermissionRestart")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while getppid() == originalPID {
            guard ContinuousClock.now < deadline else {
                log.error("The original process did not exit")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.notice("Original process \(originalPID) exited")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        for _ in 0..<3 {
            do {
                let app = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
                if app.processIdentifier != originalPID, !app.isTerminated {
                    log.notice("Reopened TakeRec in process \(app.processIdentifier)")
                    return
                }
            } catch {
                log.error("Open failed: \(error.localizedDescription, privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate()
        let alert = NSAlert()
        alert.messageText = "简录没能自动打开"
        alert.informativeText = "请在访达中打开这份简录。授权引导会接着显示。"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }
}
