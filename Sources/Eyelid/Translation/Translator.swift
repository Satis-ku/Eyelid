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

/// Translates text on this Mac with Apple's Translation, for the notch: what's typed in its field, or what's copied
/// twice in a row.
@MainActor
@Observable
final class Translator {
    /// A text to translate, and how far it got.
    struct Request: Equatable {
        let text: String
        var source: Locale.Language? = nil
        var target: Locale.Language? = nil
        var outcome: Outcome
        /// The translation of the text before, shown until this one's comes, so typing doesn't make it blink.
        var previous: String? = nil
        /// The language chosen in Settings when this was asked for, if any.
        var chosenTarget: String? = nil

        var translation: String? {
            if case .translated(let translation) = outcome { translation } else { nil }
        }
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


    /// The text in the notch's field: typed, pasted, or copied twice.
    var input = ""
    /// The latest translation, shown in the notch until the next one. Nil while there's nothing to translate.
    private(set) var request: Request?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: TranslationEngine?
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let preferredLanguages: @MainActor () -> [Locale.Language]
    /// After a pause this long in typing, what's typed is translated.
    @ObservationIgnored let typingPause: Duration
    @ObservationIgnored private var supported: [Locale.Language]?
    /// The translation under way, or waiting for typing to pause; tests wait on it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// The text `task` is about.
    @ObservationIgnored private var taskText: String?

    init(
        settings: AppSettings,
        engine: TranslationEngine? = .system,
        pasteboard: NSPasteboard = .general,
        preferredLanguages: @escaping @MainActor () -> [Locale.Language] = {
            Locale.preferredLanguages.map(Locale.Language.init(identifier:))
        },
        typingPause: Duration = .milliseconds(400)
    ) {
        self.settings = settings
        self.typingPause = typingPause
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

    /// Translates `text` right away, and shows it in the field.
    func translate(_ text: String) {
        input = text
        translateInput(after: nil)
    }

    /// Translates what's typed without waiting for a pause, as Return does.
    func translateNow() {
        translateInput(after: nil)
    }

    /// Translates what's typed, once typing pauses. The field calls this as it changes.
    func inputDidChange() {
        translateInput(after: typingPause)
    }

    /// Translates the input now, or after `delay` unless it changes again first. What's on its way, or translated
    /// already into the language chosen now, isn't translated again; what failed is tried again.
    private func translateInput(after delay: Duration?) {
        let text = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard text != taskText else { return }
        task?.cancel()
        task = nil
        taskText = nil
        if let request, request.text == text, request.translation != nil,
           request.chosenTarget == settings.translationTarget {
            return
        }
        guard !text.isEmpty else {
            request = nil
            return
        }
        guard let engine else {
            request = Request(text: text, outcome: .failed(.needsNewerMacOS))
            return
        }

        taskText = text
        if delay == nil {
            begin(text)
        }
        task = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.begin(text)
            }
            await self?.run(text, with: engine)
            guard !Task.isCancelled else { return }
            // Done with it: asking again, as after a failure, starts over.
            self?.taskText = nil
        }
    }

    /// Starts on `text`, keeping the languages and translation shown until the new ones are known.
    private func begin(_ text: String) {
        request = Request(
            text: text,
            source: request?.source,
            target: request?.target,
            outcome: .translating,
            previous: request?.translation ?? request?.previous,
            chosenTarget: settings.translationTarget
        )
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
        taskText = nil
        request = Request(text: text, outcome: .failed(failure))
    }

    /// Puts the translation on the pasteboard.
    func copyTranslation() {
        guard case .translated(let translated) = request?.outcome else { return }
        pasteboard.clearContents()
        pasteboard.setString(translated, forType: .string)
    }
}
