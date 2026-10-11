import AppKit
import SwiftUI

/// The translator in the open notch: a field for the text, typed, pasted or copied twice, and its translation.
struct TranslationPanel: View {
    @Bindable var translator: Translator
    /// Whether the field has the keyboard. The notch takes it only once the field is clicked, so the app in front
    /// keeps it until then.
    let isTyping: Bool
    let beginTyping: @MainActor () -> Void
    @State private var didCopy = false
    @State private var isFieldHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: TranslationLayout.spacing) {
            header
            field
            if let request = translator.request {
                outcome(request)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, TranslationLayout.topPadding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(translator.request?.languages ?? "Translation")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if translator.request?.translation != nil {
                Button {
                    translator.copyTranslation()
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: TranslationLayout.headerHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Copy Translation")
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            }
        }
        .frame(height: TranslationLayout.headerHeight)
    }

    private var field: some View {
        TranslationField(
            text: $translator.input,
            isTyping: isTyping,
            onChange: translator.inputDidChange,
            onSubmit: translator.translateNow
        )
        .frame(height: TranslationLayout.inputHeight(translator.input))
        .padding(.horizontal, TranslationLayout.inputPadding.width)
        .padding(.vertical, TranslationLayout.inputPadding.height)
        .background(
            .white.opacity(isTyping ? 0.12 : (isFieldHovered ? 0.1 : 0.07)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { isHovered in
            isFieldHovered = isHovered
            // A text cursor, as over any field, though the click lands on the overlay.
            if isHovered {
                NSCursor.iBeam.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFieldHovered)
        .overlay {
            if !isTyping {
                // A click asks for the keyboard, which the panel only takes on cue.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginTyping)
            }
        }
    }

    @ViewBuilder
    private func outcome(_ request: Translator.Request) -> some View {
        switch request.outcome {
        case .translating:
            if let previous = request.previous {
                // The translation so far stays, dimmed, until the next one is in.
                translation(previous)
                    .opacity(0.45)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Translating…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        case .translated(let translated):
            translation(translated)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(request.message(for: failure))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if let (title, url) = failure.settings {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private func translation(_ text: String) -> some View {
        // Scrolling needs no click, so a long translation scrolls even before the notch has the keyboard.
        ScrollView {
            Text(text)
                .font(.system(size: TranslationLayout.translationSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// Sizes of the panel's parts.
enum TranslationLayout {
    static let topPadding: CGFloat = 2
    static let headerHeight: CGFloat = 18
    static let spacing: CGFloat = 6
    static let inputSize: CGFloat = 13
    /// The field grows to this many lines, then scrolls.
    static let inputLines = 3
    static let inputPadding = CGSize(width: 8, height: 5)
    static let translationSize: CGFloat = 14

    /// The width of the open notch's content, which the panel fills.
    @MainActor
    static var width: CGFloat {
        NotchViewModel.Layout.openWidth - 2 * NotchViewModel.Layout.openHorizontalPadding
    }

    /// How tall the field is for `input`: a line at least, and `inputLines` at most, after which it scrolls.
    @MainActor
    static func inputHeight(_ input: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: inputSize)
        let line = lineHeight(font)
        let text = textHeight(input, font: font, width: width - 2 * inputPadding.width)
        return min(max(text, line), line * CGFloat(inputLines))
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

extension Translator.Request {
    /// "English → Russian", once the languages are known.
    var languages: String {
        guard let source, let target else { return "Translation" }
        return "\(TranslationLanguages.name(of: source)) → \(TranslationLanguages.name(of: target))"
    }

    func message(for failure: Translator.Failure) -> String {
        let source = source.map { TranslationLanguages.name(of: $0) } ?? "this language"
        let target = target.map { TranslationLanguages.name(of: $0) } ?? "your language"
        switch failure {
        case .needsNewerMacOS:
            return "Translating in the notch needs macOS 26 or later."
        case .pasteDenied:
            return "macOS doesn't let Eyelid read what you copy. Set Eyelid to Allow under Paste from Other Apps."
        case .nothingToTranslate:
            return "There's no text to translate."
        case .unknownLanguage:
            return "Eyelid couldn't tell which language this is."
        case .alreadyInYourLanguage:
            return "This is in \(source) already. Choose a language to translate into in Settings."
        case .languagesNotInstalled:
            return "Download \(source) and \(target) in Translation Languages to translate on this Mac."
        case .unsupportedLanguages:
            return "Apple's Translation can't translate \(source) into \(target)."
        case .failed:
            return "The translation didn't work. Try copying the text again."
        }
    }
}

extension Translator.Failure {
    /// Where in System Settings to fix it, if anywhere.
    var settings: (title: String, url: URL)? {
        switch self {
        case .pasteDenied:
            ("Open Privacy & Security", ClipboardSettings.pasteboardPrivacySettings)
        case .languagesNotInstalled:
            ("Open Language & Region", TranslationLayout.languageSettings)
        default:
            nil
        }
    }
}

extension TranslationLayout {
    /// System Settings → General → Language & Region, where Translation Languages are downloaded.
    static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
}
