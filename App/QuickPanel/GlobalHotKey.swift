import AppKit
import Carbon.HIToolbox

/// A key combination, stored with Carbon key code and Cocoa modifier flags.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    /// What the key itself shows ("Space", "K", …), captured when recording.
    var keyLabel: String

    static let optionSpace = HotKeyShortcut(
        keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Space"
    )

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        let flags = modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyLabel
    }

    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// From a key-down event; needs ⌘, ⌥ or ⌃ so plain typing never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
        keyLabel = Self.label(for: event)
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// System-wide shortcut via Carbon's RegisterEventHotKey: works while other apps are active and needs no
/// Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Returns false if the system refused (e.g. another app owns the combination).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut) -> Bool {
        unregister()
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                    // Carbon delivers hot key events on the main thread.
                    MainActor.assumeIsolated { hotKey.action() }
                    return noErr
                },
                1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
            )
        }
        let id = EventHotKeyID(signature: OSType(0x494D_4147), id: 1)  // "IMAG"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
