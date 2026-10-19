import Carbon.HIToolbox

// System-wide shortcut that toggles the popover. Carbon's RegisterEventHotKey
// needs no Accessibility permission, unlike a global key monitor.
final class HotKey {
    struct Combo {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    // Settings value → combo. "off" (or anything unknown) disables it.
    static let choices: [(id: String, combo: Combo)] = [
        ("ctrl-opt-m", Combo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥M")),
        ("ctrl-opt-cmd-m", Combo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘M")),
        ("ctrl-opt-u", Combo(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥U")),
    ]
    static let defaultID = "ctrl-opt-m"

    // The C callback can't capture context, so the action lives here.
    private static var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(id: String, action: @escaping () -> Void) {
        unregister()
        guard let combo = Self.choices.first(where: { $0.id == id })?.combo else { return }
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D45_4F57), id: 1) // 'MEOW'
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
