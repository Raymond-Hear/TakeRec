import AppKit
@preconcurrency import AVFoundation
import SwiftUI

enum RecordingPermission: String, CaseIterable, Identifiable {
    case screen, camera, microphone, keyboard

    var id: Self { self }
    var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
    var usesSettingsSwitch: Bool { self == .screen || self == .keyboard }

    var shortTitle: String {
        switch self {
        case .screen: "屏幕"
        case .camera: "摄像头"
        case .microphone: "麦克风"
        case .keyboard: "键盘"
        }
    }

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
        case .screen: "录制全屏和系统声音，并将提词器与控制条排除在成片外。"
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

    var mediaType: AVMediaType? {
        switch self {
        case .camera: .video
        case .microphone: .audio
        default: nil
        }
    }

    var promptsForMediaAccess: Bool {
        guard let mediaType else { return false }
        return AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined
    }

    var actionTitle: String { promptsForMediaAccess ? "继续" : "打开系统设置…" }
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
    @Published private(set) var isOnboarding = false
    @Published private(set) var awaitingRestart: Set<RecordingPermission> = []
    @Published private(set) var deferred: Set<RecordingPermission> = []

    private let defaults: UserDefaults
    private let checkAccess: (RecordingPermission) -> Bool
    private let settingsCoach = PermissionSettingsCoach()
    private var requested: Set<RecordingPermission> = []
    private static let seenKey = "TakeRec.Permissions.Seen"
    private static let resumeKey = "TakeRec.Permissions.Resume"
    private static let pendingKey = "TakeRec.Permissions.Current"
    private static let onboardingProcessKey = "TakeRec.Permissions.OnboardingProcess"
    private static let onboardingFinishedKey = "TakeRec.Permissions.OnboardingVerified"
    private static let deferredKey = "TakeRec.Permissions.OnboardingDeferred"
    private static let processSession = UUID().uuidString

    var hasSeenGuide: Bool { defaults.bool(forKey: Self.seenKey) }
    static var resumesGuideOnLaunch: Bool { UserDefaults.standard.bool(forKey: resumeKey) }
    var blocksRecording: Bool { isPresented || reopening }
    var onboardingStep: RecordingPermission? { isOnboarding ? nextPermission : nil }
    var onboardingNeedsRestart: Bool { isOnboarding && onboardingStep == nil && !awaitingRestart.isEmpty }
    private var nextPermission: RecordingPermission? {
        RecordingPermission.allCases.first {
            !granted.contains($0) && !awaitingRestart.contains($0) && !deferred.contains($0)
        }
    }
    static var permitsDeferring: Bool {
        #if TAKEREC_STORE
        true
        #else
        false
        #endif
    }

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

    /// Returns true while the first-run permission cards are required.
    func beginOnboarding() -> Bool {
        if isOnboarding { return true }
        if defaults.bool(forKey: Self.onboardingFinishedKey) {
            finish()
            return false
        }
        if Self.permitsDeferring {
            deferred = Set((defaults.stringArray(forKey: Self.deferredKey) ?? []).compactMap(RecordingPermission.init(rawValue:)))
        }
        refresh()
        let previous = defaults.string(forKey: Self.onboardingProcessKey)
        let hasReopened = previous != nil && previous != Self.processSession
        isOnboarding = true
        if nextPermission == nil {
            finish()
            return false
        }
        defaults.set(Self.processSession, forKey: Self.onboardingProcessKey)
        clearPending()
        note = hasReopened ? "已恢复进度。请继续设置重开后尚未确认的权限。" : nil
        isPresented = true
        return true
    }

    func refresh() {
        let latest = Set(RecordingPermission.allCases.filter(checkAccess))
        if latest != granted { granted = latest }
        let confirmed = awaitingRestart.subtracting(latest)
        if confirmed != awaitingRestart { awaitingRestart = confirmed }
        if let pending, granted.contains(pending) {
            clearPending()
            note = isOnboarding ? nil : "「\(pending.title)」已就绪。"
        }
    }

    func recheck() {
        guard !busy else { return }
        let checking = pending
        refresh()
        checkedAt = .now
        if isOnboarding {
            if let step = onboardingStep {
                note = canConfirmSwitch(step)
                    ? "当前进程还未收到权限。若系统里的开关已经打开，点「我已打开，继续」，重开后会再检查。"
                    : "请继续设置「\(step.title)」。"
            } else {
                note = nil
            }
            return
        }
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
        guard !busy, !isOnboarding else { return }
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
        if isOnboarding {
            defaults.set(true, forKey: Self.onboardingFinishedKey)
            defaults.removeObject(forKey: Self.onboardingProcessKey)
            defaults.removeObject(forKey: Self.deferredKey)
            isOnboarding = false
            awaitingRestart = []
            deferred = []
        }
        defaults.set(true, forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.resumeKey)
        clearPending()
        note = nil
        checkedAt = nil
        isPresented = false
    }

    func canConfirmSwitch(_ permission: RecordingPermission) -> Bool {
        isOnboarding && onboardingStep == permission && permission.usesSettingsSwitch && pending == permission
    }

    func confirmSwitch(_ permission: RecordingPermission) {
        guard !busy, canConfirmSwitch(permission) else { return }
        refresh()
        if !granted.contains(permission) { awaitingRestart.insert(permission) }
        clearPending()
        checkedAt = nil
        note = nil
    }

    func deferOnboardingStep() {
        guard Self.permitsDeferring, !busy, let step = onboardingStep else { return }
        deferred.insert(step)
        defaults.set(deferred.map(\.rawValue), forKey: Self.deferredKey)
        clearPending()
        note = nil
    }

    func request(_ permission: RecordingPermission) async {
        guard isPresented, !busy, !isOnboarding || onboardingStep == permission else { return }
        refresh()
        guard !granted.contains(permission), !isOnboarding || onboardingStep == permission else { return }
        settingsCoach.dismiss()
        setPending(permission)
        defaults.set(true, forKey: Self.resumeKey)
        requesting = true
        checkedAt = nil
        offersReopen = false
        note = nil
        defer { requesting = false }
        let firstRequest = requested.insert(permission).inserted
        switch permission {
        case .screen:
            if firstRequest { _ = CGRequestScreenCaptureAccess() }
        case .keyboard:
            if firstRequest { _ = CGRequestListenEventAccess() }
        case .camera, .microphone:
            if let media = permission.mediaType, permission.promptsForMediaAccess {
                _ = await AVCaptureDevice.requestAccess(for: media)
                refresh()
                if !granted.contains(permission) {
                    note = "尚未允许「\(permission.title)」。可以在系统设置中打开简录的开关。"
                }
                return
            }
        }
        refresh()
        guard !granted.contains(permission) else { return }
        let opened = await openSettings(for: permission)
        refresh()
        guard !granted.contains(permission) else { return }
        offersReopen = opened && permission.usesSettingsSwitch
        if !opened {
            note = "没能打开系统设置。请手动进入「隐私与安全性 → \(permission.title)」。"
        } else if permission.usesSettingsSwitch {
            note = isOnboarding ? nil : instructions(for: permission)
            settingsCoach.show(permission: permission, advancing: isOnboarding) { [weak self] in
                guard let self else { return }
                if self.isOnboarding { self.confirmSwitch(permission) }
                else { self.recheck() }
                self.settingsCoach.dismiss()
                NSApp.activate()
            }
        } else {
            note = instructions(for: permission)
        }
    }

    var busy: Bool { requesting || reopening }

    func beginReopen() -> Bool {
        guard isPresented, !busy else { return false }
        refresh()
        let ready = isOnboarding ? onboardingNeedsRestart : offersReopen && pending != nil
        guard ready else { return false }
        settingsCoach.dismiss()
        defaults.set(true, forKey: Self.resumeKey)
        reopening = true
        checkedAt = nil
        note = "正在重开简录…"
        return true
    }

    func failedToReopen() {
        reopening = false
        isPresented = true
        note = "没能自动重开。请按 ⌘Q 退出，再打开这份简录，授权引导会接着显示。"
    }

    private func instructions(for permission: RecordingPermission) -> String {
        if permission == .keyboard {
            return "在「输入监控」打开当前这份简录的开关。如果列表里没有简录，可以点「＋」添加。系统提示时请重开简录。"
        }
        return "请在「\(permission.title)」里打开当前这份简录的开关。系统提示重开时，授权引导会保留。"
    }

    private func clearPending() {
        settingsCoach.dismiss()
        defaults.removeObject(forKey: Self.pendingKey)
        pending = nil
        offersReopen = false
    }

    private func setPending(_ permission: RecordingPermission) {
        if permission != pending { clearPending() }
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
        Group {
            if permissions.isOnboarding { onboarding }
            else { manual }
        }
        .padding(22)
        .frame(width: 545)
        .background(WorkbenchStyle.workspace)
        .interactiveDismissDisabled()
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("设置录制权限", systemImage: "lock.shield")
                    .font(.title2.bold())
                Spacer()
                if permissions.onboardingStep != nil || permissions.onboardingNeedsRestart {
                    Button("先录一个窗口", action: finish)
                        .controlSize(.small)
                        .disabled(permissions.busy)
                }
            }
            Text("按顺序设置需要的权限。想先试录时，可直接用 macOS 选择录制窗口。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(RecordingPermission.allCases) { permission in
                    progressTile(permission)
                }
            }
            if let step = permissions.onboardingStep {
                onboardingCard(step)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(permissions.onboardingNeedsRestart ? "有权限待重开后生效" : "可以开始录制练习了",
                          systemImage: permissions.onboardingNeedsRestart ? "arrow.clockwise" : "checkmark.circle")
                        .font(.headline)
                    Text(permissions.onboardingNeedsRestart
                         ? "重开后，简录会重新检查权限，再进入第一次录制。"
                         : "跟着箭头选一个窗口，录制并导出第一个视频。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .workbenchPanel()
            }
            if let note = permissions.note { permissionNote(note) }
            HStack(spacing: 8) {
                Button("重新检查", action: recheck).disabled(permissions.busy)
                if RecordingPermissions.permitsDeferring, permissions.onboardingStep != nil {
                    Button("稍后设置", action: permissions.deferOnboardingStep)
                        .disabled(permissions.busy)
                }
                Spacer(minLength: 4)
                if let step = permissions.onboardingStep {
                    if permissions.canConfirmSwitch(step) {
                        Button("再打开系统设置…") { request(step) }.disabled(permissions.busy)
                        Button("我已打开，继续") { permissions.confirmSwitch(step) }
                            .buttonStyle(DeskPrimaryButton())
                            .keyboardShortcut(.defaultAction)
                            .disabled(permissions.busy)
                    } else {
                        Button(permissions.requesting ? "请查看系统提示…" : step.actionTitle) { request(step) }
                            .buttonStyle(DeskPrimaryButton())
                            .keyboardShortcut(.defaultAction)
                            .disabled(permissions.busy)
                    }
                } else if permissions.onboardingNeedsRestart {
                    Button(permissions.reopening ? "正在重开…" : "退出并重开简录", action: restart)
                        .buttonStyle(DeskPrimaryButton())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRestart || permissions.busy)
                } else {
                    Button("开始录制练习", action: finish)
                        .buttonStyle(DeskPrimaryButton())
                        .keyboardShortcut(.defaultAction)
                        .disabled(permissions.busy)
                }
            }
            .controlSize(.small)
        }
    }

    private func progressTile(_ permission: RecordingPermission) -> some View {
        let active = permissions.onboardingStep == permission
        let ready = permissions.granted.contains(permission)
        let waiting = permissions.awaitingRestart.contains(permission)
        let deferred = permissions.deferred.contains(permission)
        let symbol = ready ? "checkmark.circle.fill" : waiting ? "clock" : deferred ? "minus.circle" : "\(permission.number).circle"
        let status = ready ? "已就绪" : waiting ? "重开后验证" : deferred ? "稍后设置" : active ? "当前步骤" : "待设置"
        return VStack(spacing: 5) {
            Label(permission.shortTitle, systemImage: symbol)
                .font(.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(ready ? .green : active ? WorkbenchStyle.accent : .secondary)
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(active ? WorkbenchStyle.accent : WorkbenchStyle.line) }
        .accessibilityElement(children: .combine)
    }

    private func onboardingCard(_ permission: RecordingPermission) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(permission.number) / 4 · \(permission.title)", systemImage: permission.icon)
                .font(.headline)
            Text(permission.detail).font(.callout).foregroundStyle(.secondary)
            if permission.usesSettingsSwitch {
                Text("在「隐私与安全性 → \(permission.title)」找到简录，打开右侧开关。")
                    .font(.callout)
                PermissionSwitchExample()
                Text("如果没有简录，点「＋」添加当前这份 App。若系统提示退出并重开，可先选「稍后」。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if permission.promptsForMediaAccess {
                Label("点「继续」，在 macOS 弹窗中允许访问。", systemImage: "arrow.right")
                    .font(.callout)
            } else {
                Text("请在系统设置的「\(permission.title)」里打开简录的开关。").font(.callout)
            }
            Text("授权这一步不会启动录制。").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .workbenchPanel()
    }

    private var manual: some View {
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
            if let note = permissions.note { permissionNote(note) }
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
    }

    private func permissionNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
