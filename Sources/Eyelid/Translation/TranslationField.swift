import AppKit
import SwiftUI

/// The translator's field. An AppKit text field, since SwiftUI's focus doesn't reach a field in the notch's panel,
/// which takes the keyboard without Eyelid becoming the active app: keys typed then went nowhere, with a beep.
struct TranslationField: NSViewRepresentable {
    @Binding var text: String
    /// Whether the field has the keyboard. It takes it as soon as this turns true.
    let isTyping: Bool
    let onChange: @MainActor () -> Void
    /// Return.
    let onSubmit: @MainActor () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: TranslationLayout.inputSize)
        field.textColor = .white.withAlphaComponent(0.85)
        field.placeholderAttributedString = NSAttributedString(
            string: "Type or paste text to translate",
            attributes: [
                .font: NSFont.systemFont(ofSize: TranslationLayout.inputSize),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            ]
        )
        // Long text wraps onto more lines rather than running off to the side.
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Dark, for a white caret on the black notch.
        field.appearance = NSAppearance(named: .darkAqua)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        // Only text from elsewhere, such as a double copy: setting it while typing would move the caret.
        if field.stringValue != text {
            field.stringValue = text
        }
        field.wantsFocus = isTyping
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TranslationField

        init(parent: TranslationField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Return translates right away. Option-Return still starts a new line.
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

/// A text field that takes the keyboard once it's wanted and in a window, and gives it up when it's not wanted.
final class FocusingTextField: NSTextField {
    var wantsFocus = false {
        didSet {
            guard wantsFocus != oldValue else { return }
            followFocus()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followFocus()
    }

    private func followFocus() {
        guard let window else { return }
        let isEditing = currentEditor() != nil
        if wantsFocus, !isEditing {
            // The panel becomes key with the keyboard shortcut or the click, and this is then where keys go.
            window.makeFirstResponder(self)
        } else if !wantsFocus, isEditing {
            window.makeFirstResponder(nil)
        }
    }
}
