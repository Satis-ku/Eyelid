import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut, as Carbon hot keys take it: a key code and Carbon modifier flags.
struct HotKey: Equatable, Sendable {
    var keyCode: UInt32
    /// `cmdKey`, `optionKey`, `controlKey` and `shiftKey`.
    var modifiers: UInt32

    static let clipboardDefault = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    /// Two keys side by side, for one hand, that hardly any app uses: ⌥Z only types "Ω".
    static let liveActivityDefault = HotKey(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey))
    /// T for translate. ⌥T only types "†".
    static let translationDefault = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The shortcut a key press makes, or nil without ⌘, ⌥ or ⌃: a shortcut with only ⇧ would take a key
    /// away from typing everywhere.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// "⇧⌘V", with the modifiers in the order macOS menus use.
    @MainActor
    var displayString: String {
        var string = ""
        if modifiers & UInt32(controlKey) != 0 { string += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { string += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { string += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { string += "⌘" }
        return string + Self.keyName(for: keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's name, from the current Latin keyboard layout so that it reads "V" rather than "М" while
    /// typing Russian.
    @MainActor
    private static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeys[Int(keyCode)] {
            return name
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }

        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { buffer in
            UCKeyTranslate(
                buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Global keyboard shortcuts through Carbon hot keys, which, unlike event taps, need no permission.
/// A registered shortcut goes to Eyelid instead of the app in front.
@MainActor
final class HotKeyCenter {
    typealias Registration = UInt32

    private var handlers: [Registration: @MainActor () -> Void] = [:]
    private var references: [Registration: EventHotKeyRef] = [:]
    private var hotKeys: [Registration: HotKey] = [:]
    private var nextRegistration: Registration = 1
    private var eventHandler: EventHandlerRef?

    /// "EYLD", which tells Eyelid's hot keys apart from other code's in the process.
    private static let signature: OSType = 0x4559_4C44

    init() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers hot keys on the main thread.
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let registration = hotKeyID.id
                MainActor.assumeIsolated {
                    center.handlers[registration]?()
                }
                return noErr
            },
            1,
            &pressed,
            // Unretained: the center lives as long as the app.
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    /// Returns nil when the shortcut can't be registered, usually because another app already has it.
    func register(_ hotKey: HotKey, handler: @escaping @MainActor () -> Void) -> Registration? {
        let registration = nextRegistration
        nextRegistration += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: registration),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return nil }

        references[registration] = reference
        handlers[registration] = handler
        hotKeys[registration] = hotKey
        return registration
    }

    /// Whether another of Eyelid's own shortcuts has this one.
    func isRegistered(_ hotKey: HotKey) -> Bool {
        hotKeys.values.contains(hotKey)
    }

    func unregister(_ registration: Registration) {
        if let reference = references.removeValue(forKey: registration) {
            UnregisterEventHotKey(reference)
        }
        handlers[registration] = nil
        hotKeys[registration] = nil
    }
}
