import Carbon

@MainActor
final class RecordingShortcuts {
    private static let signature: OSType = 0x544B5243 // TKRC
    private let perform: @MainActor (ShortcutAction) -> Void
    private var handler: EventHandlerRef?
    private var hotKeys: [ShortcutAction: (key: ShortcutKey, ref: EventHotKeyRef)] = [:]

    init?(perform: @escaping @MainActor (ShortcutAction) -> Void) {
        self.perform = perform
        let target = GetApplicationEventTarget()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == RecordingShortcuts.signature,
                  let shortcut = ShortcutAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<RecordingShortcuts>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard shortcuts.hotKeys[shortcut] != nil else { return }
                shortcuts.perform(shortcut)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
    }

    func activate(_ desired: [ShortcutAction: ShortcutKey]) -> Set<ShortcutAction> {
        for (action, registered) in hotKeys where desired[action] != registered.key {
            UnregisterEventHotKey(registered.ref)
            hotKeys[action] = nil
        }
        for (action, key) in desired where hotKeys[action] == nil {
            if let ref = register(key, id: action.rawValue) { hotKeys[action] = (key, ref) }
        }
        return Set(hotKeys.keys)
    }

    func canRegister(_ key: ShortcutKey) -> Bool {
        guard let ref = register(key, id: 0) else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    private func register(_ key: ShortcutKey, id: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.code), key.modifiers, hotKeyID, GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &ref)
        return status == noErr ? ref : nil
    }

    deinit {
        for registered in hotKeys.values { UnregisterEventHotKey(registered.ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
