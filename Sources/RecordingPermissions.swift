import AppKit
@preconcurrency import AVFoundation
import SwiftUI

enum RecordingPermission: String, CaseIterable, Identifiable {
    case screen, camera, microphone, keyboard

    var id: Self { self }

    var title: String {
        switch self {
        case .screen: "屏幕与系统音频录制"
        case .camera: "摄像头"
        case .microphone: "麦克风"
        case .keyboard: "输入监控"
        }
    }

    var detail: String {
        switch self {
        case .screen: "全屏录制时显示提词器和录制控制条。"
        case .camera: "为录屏添加独立的人像轨。"
        case .microphone: "录制解说，和系统声音分轨。"
        case .keyboard: "可选。用于录制按键轨，供剪辑时展示。"
        }
    }

    var icon: String {
        switch self {
        case .screen: "rectangle.inset.filled"
        case .camera: "video"
        case .microphone: "mic"
        case .keyboard: "keyboard"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .screen: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .keyboard: "Privacy_ListenEvent"
        }
    }

    var allowed: Bool {
        switch self {
        case .screen: CGPreflightScreenCaptureAccess()
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .keyboard: CGPreflightListenEventAccess()
        }
    }
}

@MainActor
final class RecordingPermissions: ObservableObject {
    @Published var isPresented: Bool
    @Published private(set) var granted: Set<RecordingPermission> = []
    @Published private(set) var pending: RecordingPermission?
    @Published private(set) var requesting = false
    @Published private(set) var reopening = false
    @Published private(set) var offersReopen = false
    @Published private(set) var note: String?
    @Published private(set) var checkedAt: Date?

    private let defaults: UserDefaults
    private let checkAccess: (RecordingPermission) -> Bool
    private var requested: Set<RecordingPermission> = []
    private static let seenKey = "TakeRec.Permissions.Seen"
    private static let resumeKey = "TakeRec.Permissions.Resume"
    private static let pendingKey = "TakeRec.Permissions.Current"

    init(defaults: UserDefaults = .standard, checkAccess: @escaping (RecordingPermission) -> Bool = { $0.allowed }) {
        self.defaults = defaults
        self.checkAccess = checkAccess
        let resuming = defaults.bool(forKey: Self.resumeKey)
        isPresented = !defaults.bool(forKey: Self.seenKey) || resuming
        if resuming {
            pending = defaults.string(forKey: Self.pendingKey).flatMap(RecordingPermission.init(rawValue:))
        }
        refresh()
        if let pending {
            requested.insert(pending)
            note = "重开后「\(pending.title)」仍未就绪。" + instructions(for: pending)
        }
    }

    func refresh() {
        let latest = Set(RecordingPermission.allCases.filter(checkAccess))
        if latest != granted { granted = latest }
        if let pending, granted.contains(pending) {
            self.pending = nil
            defaults.removeObject(forKey: Self.pendingKey)
            offersReopen = false
            note = "「\(pending.title)」已就绪。"
        }
    }

    func recheck() {
        guard !busy else { return }
        let checking = pending
        refresh()
        checkedAt = .now
        if let checking {
            if !granted.contains(checking) {
                note = "当前简录仍无法使用「\(checking.title)」。" + instructions(for: checking)
            }
        } else {
            let remaining = RecordingPermission.allCases.filter { !granted.contains($0) }.map(\.title)
            note = remaining.isEmpty ? "录制权限均已就绪。" : "尚未就绪：\(remaining.joined(separator: "、"))。"
        }
    }

    func open(focusing permission: RecordingPermission? = nil) {
        guard !busy else { return }
        refresh()
        if let permission, !granted.contains(permission) {
            setPending(permission)
            note = instructions(for: permission)
        }
        defaults.set(true, forKey: Self.resumeKey)
        isPresented = true
    }

    func finish() {
        guard !busy else { return }
        defaults.set(true, forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.resumeKey)
        defaults.removeObject(forKey: Self.pendingKey)
        pending = nil
        note = nil
        checkedAt = nil
        offersReopen = false
        isPresented = false
    }

    func request(_ permission: RecordingPermission) async {
        guard isPresented, !busy else { return }
        refresh()
        guard !granted.contains(permission) else { return }
        setPending(permission)
        defaults.set(true, forKey: Self.resumeKey)
        requesting = true
        checkedAt = nil
        offersReopen = false
        note = "正在打开「\(permission.title)」设置…"
        defer { requesting = false }
        let firstRequest = requested.insert(permission).inserted
        switch permission {
        case .screen:
            if firstRequest { _ = CGRequestScreenCaptureAccess() }
        case .keyboard:
            if firstRequest { _ = CGRequestListenEventAccess() }
        case .camera, .microphone:
            let media: AVMediaType = permission == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            }
        }
        refresh()
        guard !granted.contains(permission) else { return }
        let opened = await openSettings(for: permission)
        refresh()
        guard !granted.contains(permission) else { return }
        offersReopen = opened
        note = (opened ? "" : "没能打开系统设置。请手动进入「隐私与安全性」。") + instructions(for: permission)
    }

    var busy: Bool { requesting || reopening }

    func beginReopen() -> Bool {
        guard isPresented, !busy, offersReopen, pending != nil else { return false }
        defaults.set(true, forKey: Self.resumeKey)
        reopening = true
        checkedAt = nil
        note = "正在重开简录…"
        return true
    }

    func failedToReopen() {
        reopening = false
        note = "没能自动重开。请按 ⌘Q 退出，再打开这份简录，授权引导会接着显示。"
    }

    static func launchReplacement(at url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        let replacement = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        guard replacement.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !replacement.isTerminated else { throw CocoaError(.executableLoad) }
    }

    private func instructions(for permission: RecordingPermission) -> String {
        if permission == .keyboard {
            return "在「输入监控」打开简录。开关已开启却仍未就绪时，先移除旧条目，再点「＋」添加当前这份简录。添加后按系统提示重开。"
        }
        return "请在「\(permission.title)」里允许当前这份简录。若系统提示重开，授权引导会保留。"
    }

    private func setPending(_ permission: RecordingPermission) {
        if permission != pending { offersReopen = false }
        pending = permission
        defaults.set(permission.rawValue, forKey: Self.pendingKey)
    }

    private func openSettings(for permission: RecordingPermission) async -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)") else { return false }
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }
}

struct RecordingPermissionGuide: View {
    @ObservedObject var permissions: RecordingPermissions
    let canRestart: Bool
    let restart: () -> Void
    let request: (RecordingPermission) -> Void
    let recheck: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("设置录制权限", systemImage: "lock.shield")
                .font(.title2.bold())
            Text("按需设置录制权限。输入监控只用于按键轨，可稍后开启。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(RecordingPermission.allCases) { permission in
                    if permission != .screen { Divider() }
                    permissionRow(permission)
                }
            }
            .padding(.horizontal, 12)
            .workbenchPanel()
            if let note = permissions.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新检查", action: recheck).disabled(permissions.busy)
                if permissions.offersReopen {
                    Button(permissions.reopening ? "正在重开…" : "退出并重开", action: restart)
                        .disabled(!canRestart || permissions.busy)
                        .help(canRestart ? "重开后返回这一步，录制画面需要重选" : "请先保存并关闭当前工程")
                }
                if let checkedAt = permissions.checkedAt {
                    Text("已检查 \(checkedAt.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(permissions.pending == .keyboard ? "暂不设置" : "完成", action: finish)
                    .buttonStyle(DeskPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(permissions.busy)
            }
            .controlSize(.small)
        }
        .padding(22)
        .frame(width: 545)
        .background(WorkbenchStyle.workspace)
        .interactiveDismissDisabled()
    }

    private func permissionRow(_ permission: RecordingPermission) -> some View {
        HStack(spacing: 10) {
            Image(systemName: permission.icon).foregroundStyle(WorkbenchStyle.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.callout.weight(.semibold))
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if permissions.granted.contains(permission) {
                Label("已就绪", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else {
                Button(permission == .keyboard ? "设置输入监控…" : "设置…") { request(permission) }
                    .controlSize(.small)
                    .disabled(permissions.busy)
                    .accessibilityLabel("设置\(permission.title)")
            }
        }
        .padding(.vertical, 10)
    }
}
