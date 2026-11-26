import AppKit
import SwiftUI

struct PermissionSwitchExample: View {
    var draggable = false

    var body: some View {
        HStack(spacing: 9) {
            if draggable {
                appBadge.onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .help("拖动这个图标到系统设置的权限列表")
                    .accessibilityHint("可以把当前 App 拖入权限列表")
            } else {
                appBadge
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.right").font(.callout.bold()).foregroundStyle(WorkbenchStyle.accent)
            Capsule().fill(WorkbenchStyle.accent).frame(width: 32, height: 18)
                .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 14).padding(.trailing, 2) }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WorkbenchStyle.workspace, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("示意：在系统设置中打开简录这一行的开关")
    }

    private var appBadge: some View {
        HStack(spacing: 7) {
            Image(nsImage: TakeRecBrand.icon).resizable().scaledToFit().frame(width: 26, height: 26)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "简录")
                .font(.callout.weight(.semibold)).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

@MainActor
final class PermissionSettingsCoach {
    private static let settingsID = "com.apple.systempreferences"
    private var panel: NSPanel?
    private var tracking: Task<Void, Never>?

    func show(permission: RecordingPermission, advancing: Bool, onContinue: @escaping () -> Void) {
        dismiss()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "简录授权引导"
        let placement = CoachDirection()
        let view = SettingsCoachCard(permission: permission, advancing: advancing, direction: placement, onContinue: onContinue)
        let host = PermissionCoachHost(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(size)
        self.panel = panel
        tracking = Task { [weak self] in
            var foundSettings = false
            while !Task.isCancelled, self?.panel === panel {
                if let settings = NSWorkspace.shared.frontmostApplication,
                   settings.bundleIdentifier == Self.settingsID,
                   let frame = Self.settingsFrame(for: settings.processIdentifier),
                   let screen = NSScreen.screens.max(by: {
                       Self.overlap($0.frame, frame) < Self.overlap($1.frame, frame)
                   }), Self.overlap(screen.frame, frame) > 0 {
                    foundSettings = true
                    let position = Self.placeCard(size, nextTo: frame, in: screen.visibleFrame)
                    if placement.arrow != position.arrow { placement.arrow = position.arrow }
                    if panel.frame != position.frame { panel.setFrame(position.frame, display: true) }
                    if !panel.isVisible { panel.orderFrontRegardless() }
                } else {
                    panel.orderOut(nil)
                    if foundSettings && (NSApp.isActive || NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsID).isEmpty) {
                        self?.dismiss()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    func dismiss() {
        tracking?.cancel()
        tracking = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private static func settingsFrame(for pid: pid_t) -> CGRect? {
        guard let mainTop = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Read only WindowServer geometry, including before Screen Recording is granted.
        return windows.compactMap { entry -> CGRect? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 420, frame.height >= 320 else { return nil }
            return CGRect(x: frame.minX, y: mainTop - frame.maxY, width: frame.width, height: frame.height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    static func placeCard(_ size: CGSize, nextTo settings: CGRect, in visible: CGRect) -> (frame: CGRect, arrow: String) {
        let gap: CGFloat = 8
        let width = min(size.width, max(1, visible.width - 2 * gap))
        let height = min(size.height, max(1, visible.height - 2 * gap))
        let left = visible.minX + gap
        let right = visible.maxX - width - gap
        let bottom = visible.minY + gap
        let top = visible.maxY - height - gap
        let y = min(top, max(bottom, settings.maxY - height - 26))
        let x = min(right, max(left, settings.midX - width / 2))
        if settings.maxX + gap <= right {
            return (CGRect(x: settings.maxX + gap, y: y, width: width, height: height), "arrow.left")
        }
        if settings.minX - gap - width >= left {
            return (CGRect(x: settings.minX - gap - width, y: y, width: width, height: height), "arrow.right")
        }
        if settings.minY - gap - height >= bottom {
            return (CGRect(x: x, y: settings.minY - gap - height, width: width, height: height), "arrow.up")
        }
        if settings.maxY + gap <= top {
            return (CGRect(x: x, y: settings.maxY + gap, width: width, height: height), "arrow.down")
        }
        // On a small display, keep the right-hand permission switches clear.
        return (CGRect(x: left, y: bottom, width: width, height: height), "arrow.up.right")
    }
}

private final class CoachDirection: ObservableObject {
    @Published var arrow = "arrow.left"
}

private final class PermissionCoachHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SettingsCoachCard: View {
    let permission: RecordingPermission
    let advancing: Bool
    @ObservedObject var direction: CoachDirection
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: direction.arrow).font(.system(size: 14, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(WorkbenchStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(advancing ? "授权引导 · \(permission.number)/4" : "简录授权引导").font(.caption.weight(.semibold))
            }
            .foregroundStyle(WorkbenchStyle.accent)
            Text(permission.title).font(.headline)
            Text("找到「简录」这一行，打开右侧开关。").font(.callout)
            PermissionSwitchExample(draggable: true)
            Text("列表里没有简录时，把上面的 App 图标拖进去，或点「＋」选择当前这份简录.app。")
                .font(.caption).foregroundStyle(.secondary)
            if advancing {
                Text("若系统提示重开，可以先选「稍后」。").font(.caption).foregroundStyle(.secondary)
            }
            Button(advancing ? "我已打开，继续" : "回到简录检查", action: onContinue)
                .buttonStyle(DeskPrimaryButton())
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 282, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(WorkbenchStyle.line).allowsHitTesting(false) }
    }
}
