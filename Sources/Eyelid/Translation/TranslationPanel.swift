import AppKit
import SwiftUI

/// The translation of what was copied, in the open notch: the two languages, the original, and the translation.
struct TranslationPanel: View {
    let translator: Translator
    @State private var didCopy = false

    var body: some View {
        if let request = translator.request {
            VStack(alignment: .leading, spacing: TranslationLayout.spacing) {
                header(request)
                if !request.text.isEmpty {
                    Text(request.text)
                        .font(.system(size: TranslationLayout.sourceSize))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(TranslationLayout.sourceLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                outcome(request)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, TranslationLayout.topPadding)
        }
    }

    private func header(_ request: Translator.Request) -> some View {
        HStack(spacing: 8) {
            Text(request.languages)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if case .translated = request.outcome {
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

    @ViewBuilder
    private func outcome(_ request: Translator.Request) -> some View {
        switch request.outcome {
        case .translating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Translating…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .translated(let translated):
            // Scrolling needs no click, so it works although the notch never takes the keyboard.
            ScrollView {
                Text(translated)
                    .font(.system(size: TranslationLayout.translationSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
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
}

/// Sizes shared by the panel and the notch, which grows to fit a long translation.
enum TranslationLayout {
    static let topPadding: CGFloat = 2
    static let headerHeight: CGFloat = 18
    static let spacing: CGFloat = 6
    static let sourceSize: CGFloat = 12
    static let sourceLines = 2
    static let translationSize: CGFloat = 14
    /// A line of "Translating…", or a message and a button.
    static let translatingHeight: CGFloat = 18
    static let failureHeight: CGFloat = 54

    /// How tall the panel would like to be for `request`, `width` wide.
    @MainActor
    static func height(for request: Translator.Request, width: CGFloat) -> CGFloat {
        var height = topPadding + headerHeight
        if !request.text.isEmpty {
            let font = NSFont.systemFont(ofSize: sourceSize)
            let lines = lineHeight(font) * CGFloat(sourceLines)
            height += spacing + min(textHeight(request.text, font: font, width: width), lines)
        }
        height += spacing
        switch request.outcome {
        case .translating:
            height += translatingHeight
        case .translated(let translated):
            height += textHeight(translated, font: .systemFont(ofSize: translationSize, weight: .medium), width: width)
        case .failed:
            height += failureHeight
        }
        return ceil(height)
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
