import AppKit
import Carbon.HIToolbox

/// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z for a text field in the notch. Other apps send them from their Edit menu, which the
/// notch panel doesn't reach without Eyelid in front, so the panel sends them itself.
enum TextEditingKey: Equatable {
    case cut
    case copy
    case paste
    case selectAll
    case undo
    case redo

    init?(keyCode: Int, charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) {
        let modifiers = modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
        let isShifted = modifiers.contains(.shift)

        // The letter the layout puts there, or with a layout that types no Latin letters, such as Russian, the key's
        // place on a US keyboard, as macOS does for menu shortcuts.
        let letter = charactersIgnoringModifiers?.lowercased()
        let key = if let letter, letter.count == 1, letter.first?.isASCII == true, letter.first?.isLetter == true {
            letter
        } else {
            Self.usLetters[keyCode]
        }

        switch (key, isShifted) {
        case ("x", false): self = .cut
        case ("c", false): self = .copy
        case ("v", false): self = .paste
        case ("a", false): self = .selectAll
        case ("z", false): self = .undo
        case ("z", true): self = .redo
        default: return nil
        }
    }

    init?(event: NSEvent) {
        self.init(
            keyCode: Int(event.keyCode),
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        )
    }

    /// What the text field's editor does for it.
    var action: Selector {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        }
    }

    private static let usLetters: [Int: String] = [
        kVK_ANSI_X: "x", kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_A: "a", kVK_ANSI_Z: "z",
    ]
}
