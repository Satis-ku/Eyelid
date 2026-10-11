import AppKit
import Observation
import os
import Translation

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Translation")

/// What the translator needs from Apple's Translation, so tests can stand in for it.
struct TranslationEngine: Sendable {
    enum Status: Sendable {
        case installed
        /// Supported, but not downloaded on this Mac yet.
        case notInstalled
        case unsupported
    }

    enum Failure: Error {
        case notInstalled
        case unsupported
    }

    var supportedLanguages: @Sendable () async -> [Locale.Language]
    var status: @Sendable (_ source: Locale.Language, _ target: Locale.Language) async -> Status
    var translate: @Sendable (_ text: String, _ source: Locale.Language, _ target: Locale.Language) async throws -> String

    /// Apple's, on this Mac. From macOS 26 it translates with the languages already downloaded without showing
    /// anything, which is what the notch needs. Nil before that.
    static var system: TranslationEngine? {
        guard #available(macOS 26.0, *) else { return nil }
        return TranslationEngine(
            supportedLanguages: {
                await LanguageAvailability().supportedLanguages
            },
            status: { source, target in
                switch await LanguageAvailability().status(from: source, to: target) {
                case .installed: .installed
                case .supported: .notInstalled
                case .unsupported: .unsupported
                @unknown default: .unsupported
                }
            },
            translate: { text, source, target in
                let session = TranslationSession(installedSource: source, target: target)
                do {
                    return try await session.translate(text).targetText
                } catch TranslationError.notInstalled {
                    throw Failure.notInstalled
                } catch TranslationError.unsupportedLanguagePairing {
                    throw Failure.unsupported
                }
            }
        )
    }
}

/// Translates text on this Mac with Apple's Translation, for the notch: what's copied twice in a row, or with the
/// shortcut, what's copied already.
@MainActor
@Observable
final class Translator {
    /// A text to translate, and how far it got.
    struct Request: Equatable {
        let text: String
        var source: Locale.Language?
        var target: Locale.Language?
        var outcome: Outcome
    }

    enum Outcome: Equatable {
        case translating
        case translated(String)
        case failed(Failure)
    }

    enum Failure: Equatable {
        /// Translating without asking to download languages needs macOS 26.
        case needsNewerMacOS
        /// macOS doesn't let Eyelid read what other apps copy.
        case pasteDenied
        case nothingToTranslate
        case unknownLanguage
        /// The text is in the only language there is to translate into.
        case alreadyInYourLanguage
        /// The languages can be downloaded in System Settings, and aren't yet.
        case languagesNotInstalled
        case unsupportedLanguages
        case failed
    }

    /// Longer texts are cut here: the notch has room for a few paragraphs at most.
    static let maxLength = 5_000

    /// The latest translation, shown in the notch until the next one.
    private(set) var request: Request?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: TranslationEngine?
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let preferredLanguages: @MainActor () -> [Locale.Language]
    @ObservationIgnored private var supported: [Locale.Language]?
    /// The translation under way; tests wait on it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(
        settings: AppSettings,
        engine: TranslationEngine? = .system,
        pasteboard: NSPasteboard = .general,
        preferredLanguages: @escaping @MainActor () -> [Locale.Language] = {
            Locale.preferredLanguages.map(Locale.Language.init(identifier:))
        }
    ) {
        self.settings = settings
        self.engine = engine
        self.pasteboard = pasteboard
        self.preferredLanguages = preferredLanguages
    }

    /// Whether this Mac can translate in the notch at all.
    var isAvailable: Bool {
        engine != nil
    }

    /// The languages to choose from in Settings, sorted by name.
    func supportedLanguages() async -> [Locale.Language] {
        if let supported {
            return supported
        }
        let languages = await engine?.supportedLanguages() ?? []
        let sorted = languages.sorted {
            TranslationLanguages.fullName(of: $0).localizedStandardCompare(TranslationLanguages.fullName(of: $1))
                == .orderedAscending
        }
        supported = sorted
        return sorted
    }

    /// Translates the text on the pasteboard. Unless Eyelid is allowed to read it, macOS asks the user first.
    func translateCopiedText() {
        guard engine != nil else {
            fail(text: "", .needsNewerMacOS)
            return
        }
        guard ClipboardHistory.Access(pasteboard) != .denied else {
            fail(text: "", .pasteDenied)
            return
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            fail(text: "", .nothingToTranslate)
            return
        }
        translate(text)
    }

    func translate(_ text: String) {
        task?.cancel()
        guard let engine else {
            fail(text: text, .needsNewerMacOS)
            return
        }
        let text = String(text.prefix(Self.maxLength))
        request = Request(text: text, outcome: .translating)
        task = Task { [weak self] in
            await self?.run(text, with: engine)
        }
    }

    private func run(_ text: String, with engine: TranslationEngine) async {
        let supported = await supportedLanguages()
        let preferred = preferredLanguages()
        guard !Task.isCancelled else { return }
        guard let source = TranslationLanguages.detect(text, among: supported, preferring: preferred) else {
            finish(text, .failed(.unknownLanguage))
            return
        }
        request?.source = source
        let chosen = settings.translationTarget.map(Locale.Language.init(identifier:))
        guard let target = TranslationLanguages.target(for: source, chosen: chosen, among: supported, preferring: preferred)
        else {
            // Only when all the user's languages are this one, and it's English.
            finish(text, .failed(.alreadyInYourLanguage))
            return
        }
        request?.target = target

        switch await engine.status(source, target) {
        case .installed:
            break
        case .notInstalled:
            finish(text, .failed(.languagesNotInstalled))
            return
        case .unsupported:
            finish(text, .failed(.unsupportedLanguages))
            return
        }
        guard !Task.isCancelled else { return }

        do {
            let translated = try await engine.translate(text, source, target)
            finish(text, .translated(translated))
        } catch TranslationEngine.Failure.notInstalled {
            finish(text, .failed(.languagesNotInstalled))
        } catch TranslationEngine.Failure.unsupported {
            finish(text, .failed(.unsupportedLanguages))
        } catch {
            logger.error("Could not translate: \(error.localizedDescription, privacy: .public)")
            finish(text, .failed(.failed))
        }
    }

    /// Shows how the translation of `text` ended, unless another one took its place.
    private func finish(_ text: String, _ outcome: Outcome) {
        guard !Task.isCancelled, request?.text == text else { return }
        request?.outcome = outcome
    }

    private func fail(text: String, _ failure: Failure) {
        task?.cancel()
        task = nil
        request = Request(text: text, outcome: .failed(failure))
    }

    /// Puts the translation on the pasteboard.
    func copyTranslation() {
        guard case .translated(let translated) = request?.outcome else { return }
        pasteboard.clearContents()
        pasteboard.setString(translated, forType: .string)
    }
}
