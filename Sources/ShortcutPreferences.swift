import AppKit
import Carbon

enum ShortcutAction: UInt32, CaseIterable, Identifiable, Codable {
    case start = 1, stop, previousPage, nextPage, togglePrompt
    case playback, save, splitTrack, splitAll, deleteClip, undo

    static let recording: [Self] = [.start, .stop, .togglePrompt, .previousPage, .nextPage]
    static let editing: [Self] = [.playback, .save, .splitTrack, .splitAll, .deleteClip, .undo]

    var id: Self { self }
    var isGlobal: Bool { Self.recording.contains(self) }

    var title: String {
        switch self {
        case .start: "开始录制"
        case .stop: "结束录制"
        case .previousPage: "提词器上一页"
        case .nextPage: "提词器下一页"
        case .togglePrompt: "显示或隐藏提词器"
        case .playback: "播放 / 暂停预览"
        case .save: "保存工程"
        case .splitTrack: "分割当前轨道"
        case .splitAll: "分割所有轨道"
        case .deleteClip: "删除所选片段"
        case .undo: "撤销片段操作"
        }
    }

    var defaultKey: ShortcutKey {
        let recordingModifiers = controlKey | shiftKey
        switch self {
        case .start: return ShortcutKey(kVK_ANSI_R, "R", recordingModifiers)
        case .stop: return ShortcutKey(kVK_ANSI_S, "S", recordingModifiers)
        case .previousPage: return ShortcutKey(kVK_LeftArrow, "←", recordingModifiers)
        case .nextPage: return ShortcutKey(kVK_RightArrow, "→", recordingModifiers)
        case .togglePrompt: return ShortcutKey(kVK_ANSI_T, "T", recordingModifiers)
        case .playback: return ShortcutKey(kVK_Space, "空格")
        case .save: return ShortcutKey(kVK_ANSI_S, "S", cmdKey)
        case .splitTrack: return ShortcutKey(kVK_ANSI_K, "K", cmdKey)
        case .splitAll: return ShortcutKey(kVK_ANSI_K, "K", cmdKey | shiftKey)
        case .deleteClip: return ShortcutKey(kVK_Delete, "⌫")
        case .undo: return ShortcutKey(kVK_ANSI_Z, "Z", cmdKey)
        }
    }
}

struct ShortcutKey: Codable, Equatable {
    let code: UInt16
    let modifiers: UInt32
    let name: String

    private static let modifierKeys: [(NSEvent.ModifierFlags, Int, String)] = [
        (.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
        (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
    ]
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]
    private static let specialKeys = [
        kVK_Space: "空格", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌅", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down"
    ]

    init(_ code: Int, _ name: String, _ modifiers: Int = 0) {
        self.code = UInt16(code)
        self.name = name
        self.modifiers = UInt32(modifiers)
    }

    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = Self.modifiers(for: event)
        let name: String
        if let index = Self.functionKeys.firstIndex(of: code) {
            name = "F\(index + 1)"
        } else if let special = Self.specialKeys[code] {
            guard modifiers != 0 || [kVK_Space, kVK_Delete, kVK_ForwardDelete].contains(code) else { return nil }
            name = special
        } else {
            guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
                  let character = event.characters(byApplyingModifiers: [])?.first,
                  !character.isWhitespace, !character.isNewline, !character.isASCIIControl else { return nil }
            name = String(character).uppercased()
        }
        self.init(code, name, Int(modifiers))
    }

    var label: String {
        Self.modifierKeys.filter { modifiers & UInt32($0.1) != 0 }.map(\.2).joined() + name
    }

    var hasGlobalModifier: Bool { modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 }

    var isWindowCommand: Bool {
        (modifiers == UInt32(cmdKey) && ["Q", "W", "H", "M", ","].contains(name)) ||
            (modifiers == UInt32(cmdKey | optionKey) && name == "H")
    }

    func matches(_ event: NSEvent) -> Bool {
        code == event.keyCode && modifiers == Self.modifiers(for: event)
    }

    static func modifiers(for event: NSEvent) -> UInt32 {
        modifierKeys.reduce(0) { value, modifier in
            event.modifierFlags.contains(modifier.0) ? value | UInt32(modifier.1) : value
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code && lhs.modifiers == rhs.modifiers
    }
}

private extension Character {
    var isASCIIControl: Bool { asciiValue.map { $0 < 32 || $0 == 127 } ?? false }
}

@MainActor
final class ShortcutPreferences: ObservableObject {
    private static let storageKey = "TakeRec.ShortcutOverrides.v1"
    @Published private(set) var overrides: [ShortcutAction: ShortcutKey]
    @Published var learning: ShortcutAction?
    var canRegisterGlobal: ((ShortcutKey) -> Bool)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
        overrides = saved.flatMap { try? JSONDecoder().decode([ShortcutAction: ShortcutKey].self, from: $0) } ?? [:]
    }

    subscript(action: ShortcutAction) -> ShortcutKey { overrides[action] ?? action.defaultKey }

    func action(for event: NSEvent) -> ShortcutAction? {
        ShortcutAction.editing.first { self[$0].matches(event) }
    }

    func assign(_ key: ShortcutKey, to action: ShortcutAction) -> String? {
        if key.isWindowCommand { return "\(key.label) 已用于简录的系统菜单，请换一组。" }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self[$0] == key }) {
            return "\(key.label) 已用于「\(conflict.title)」，请换一组。"
        }
        if action.isGlobal {
            guard key.hasGlobalModifier else { return "全局快捷键需要包含 Control、Option 或 Command。" }
            guard canRegisterGlobal?(key) == true else { return "系统未能注册 \(key.label)，请换一组。" }
        }
        overrides[action] = key == action.defaultKey ? nil : key
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey)
        return nil
    }

    func reset() {
        overrides = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }
}
