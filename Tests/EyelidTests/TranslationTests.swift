import AppKit
import Foundation
import Testing
@testable import Eyelid

extension TranslationEngine {
    /// Some of the languages Apple's Translation supports, as it lists them, and a translation that shows its target.
    static func fake(
        status: Status = .installed,
        translate: @escaping @Sendable (String, Locale.Language, Locale.Language) async throws -> String = {
            text, _, target in "\(target.minimalIdentifier): \(text)"
        }
    ) -> TranslationEngine {
        TranslationEngine(
            supportedLanguages: {
                ["en-Latn-US", "en-Latn-GB", "ru-Cyrl-RU", "uk-Cyrl-UA", "de-Latn-DE", "fr-Latn-FR", "zh-Hans-CN", "zh-Hant-TW"]
                    .map(Locale.Language.init(identifier:))
            },
            status: { _, _ in status },
            translate: translate
        )
    }
}

@Suite("Translation languages")
struct TranslationLanguagesTests {
    private let supported = [
        "en-Latn-US", "en-Latn-GB", "ru-Cyrl-RU", "uk-Cyrl-UA", "de-Latn-DE", "fr-Latn-FR", "zh-Hans-CN", "zh-Hant-TW",
    ].map(Locale.Language.init(identifier:))
    /// As macOS reports them for someone with English, then Russian, in Language & Region.
    private let preferred = ["en-US", "ru-US"].map(Locale.Language.init(identifier:))

    /// Short texts lean towards the user's languages: on their own, these read as Bulgarian and Polish.
    @Test(arguments: [
        ("Привет", "ru-Cyrl-RU"),
        ("OK", "en-Latn-US"),
        ("Hallo Welt, wie geht es dir heute?", "de-Latn-DE"),
        ("Bonjour tout le monde, comment ça va ?", "fr-Latn-FR"),
        ("Привіт, як справи? Що нового?", "uk-Cyrl-UA"),
    ])
    func detectsTheLanguage(text: String, expected: String) {
        let language = TranslationLanguages.detect(text, among: supported, preferring: preferred)

        #expect(language?.maximalIdentifier == expected)
    }

    @Test(arguments: [
        // Into the first language, or the next one for text already in it, in the user's own variant.
        ("de-Latn-DE", nil, "en-Latn-US"),
        ("en-Latn-US", nil, "ru-Cyrl-RU"),
        ("ru-Cyrl-RU", nil, "en-Latn-US"),
        // A chosen language wins, unless the text is in it already.
        ("ru-Cyrl-RU", "en-Latn-GB", "en-Latn-GB"),
        ("de-Latn-DE", "fr-Latn-FR", "fr-Latn-FR"),
        ("fr-Latn-FR", "fr-Latn-FR", "en-Latn-US"),
    ] as [(String, String?, String)])
    func choosesTheTarget(source: String, chosen: String?, expected: String) {
        let target = TranslationLanguages.target(
            for: Locale.Language(identifier: source),
            chosen: chosen.map(Locale.Language.init(identifier:)),
            among: supported,
            preferring: preferred
        )

        #expect(target?.maximalIdentifier == expected)
    }

    @Test func englishWithOnlyEnglishHasNothingToGoInto() {
        let target = TranslationLanguages.target(
            for: Locale.Language(identifier: "en-Latn-US"),
            chosen: nil,
            among: supported,
            preferring: [Locale.Language(identifier: "en-US")]
        )

        #expect(target == nil)
    }

    @Test func tellsChineseScriptsApart() {
        #expect(TranslationLanguages.recognizerLanguage(for: Locale.Language(identifier: "zh-Hans-CN")) == .simplifiedChinese)
        #expect(TranslationLanguages.recognizerLanguage(for: Locale.Language(identifier: "zh-TW")) == .traditionalChinese)
    }
}

@Suite("Copying twice")
struct DoubleCopyTests {
    private let start = ContinuousClock.now

    /// Whether each copy, this many milliseconds in, is the second of two.
    private func seconds(_ offsets: [Int]) -> [Bool] {
        var detector = DoubleCopy()
        return offsets.map { detector.isSecond(at: start + .milliseconds($0)) }
    }

    @Test func secondCopySoonAfterIsADoubleCopy() {
        #expect(seconds([0, 300]) == [false, true])
    }

    /// The later copy can still be the first of two.
    @Test func copiesFarApartAreNot() {
        #expect(seconds([0, 1_000, 1_300]) == [false, false, true])
    }

    @Test func threeCopiesTranslateOnce() {
        #expect(seconds([0, 200, 400]) == [false, true, false])
    }
}

@MainActor
@Suite("Watching for copies")
struct DoubleCopyWatcherTests {
    private final class Count {
        var value = 0
    }

    private let pasteboard = NSPasteboard.withUniqueName()
    private let start = ContinuousClock.now

    private func makeWatcher(_ count: Count) -> DoubleCopyWatcher {
        let watcher = DoubleCopyWatcher(pasteboard: pasteboard)
        watcher.onDoubleCopy = { count.value += 1 }
        return watcher
    }

    private func copy(_ text: String, as types: [NSPasteboard.PasteboardType] = []) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        for type in types {
            pasteboard.setData(Data(), forType: type)
        }
    }

    @Test func textCopiedTwiceAsksForATranslation() {
        let count = Count()
        let watcher = makeWatcher(count)

        copy("Hello")
        watcher.check(at: start)
        copy("Hello")
        watcher.check(at: start + .milliseconds(250))

        #expect(count.value == 1)
    }

    /// Some apps write to the pasteboard more than once for one ⌘C.
    @Test func severalChangesBetweenLooksAreOneCopy() {
        let count = Count()
        let watcher = makeWatcher(count)

        copy("Hello")
        copy("Hello")
        watcher.check(at: start)
        watcher.check(at: start + .milliseconds(50))

        #expect(count.value == 0)
    }

    @Test func passwordsAreLeftAlone() {
        let count = Count()
        let watcher = makeWatcher(count)
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

        copy("hunter2", as: [concealed])
        watcher.check(at: start)
        copy("hunter2", as: [concealed])
        watcher.check(at: start + .milliseconds(250))

        #expect(count.value == 0)
    }

    @Test func filesAreNotText() throws {
        let count = Count()
        let watcher = makeWatcher(count)
        let file = URL(filePath: "/tmp/notes.txt") as NSURL

        for offset in [0, 250] {
            pasteboard.clearContents()
            pasteboard.writeObjects([file])
            watcher.check(at: start + .milliseconds(offset))
        }

        #expect(count.value == 0)
    }
}

@MainActor
@Suite("Translator")
struct TranslatorTests {
    private let pasteboard = NSPasteboard.withUniqueName()
    private let settings = AppSettings(defaults: InMemorySettingsStore())

    private func makeTranslator(engine: TranslationEngine? = .fake()) -> Translator {
        Translator(
            settings: settings,
            engine: engine,
            pasteboard: pasteboard,
            preferredLanguages: { ["en-US", "ru-US"].map(Locale.Language.init(identifier:)) },
            typingPause: .milliseconds(10)
        )
    }

    /// The texts the engine was asked to translate.
    private actor Calls {
        var texts: [String] = []

        func add(_ text: String) {
            texts.append(text)
        }
    }

    @Test func translatesIntoTheUsersOtherLanguage() async throws {
        let translator = makeTranslator()

        translator.translate("The quick brown fox jumps over the lazy dog")
        #expect(translator.request?.outcome == .translating)
        await translator.task?.value

        let request = try #require(translator.request)
        #expect(request.source?.maximalIdentifier == "en-Latn-US")
        #expect(request.target?.maximalIdentifier == "ru-Cyrl-RU")
        #expect(request.outcome == .translated("ru: The quick brown fox jumps over the lazy dog"))
        #expect(request.languages == TranslationLanguages.name(of: Locale.Language(identifier: "en")) + " → "
            + TranslationLanguages.name(of: Locale.Language(identifier: "ru")))
    }

    @Test func translatesWhatsCopied() async {
        let translator = makeTranslator()
        pasteboard.clearContents()
        pasteboard.setString("  Привет, как дела?\n", forType: .string)

        translator.translateCopiedText()
        await translator.task?.value

        #expect(translator.request?.text == "Привет, как дела?")
        #expect(translator.request?.outcome == .translated("en: Привет, как дела?"))
    }

    @Test func nothingCopiedIsNothingToTranslate() {
        let translator = makeTranslator()
        pasteboard.clearContents()

        translator.translateCopiedText()

        #expect(translator.request?.outcome == .failed(.nothingToTranslate))
    }

    @Test func languagesNotDownloadedSaySo() async {
        let translator = makeTranslator(engine: .fake(status: .notInstalled))

        translator.translate("Guten Morgen, wie geht es dir heute?")
        await translator.task?.value

        #expect(translator.request?.outcome == .failed(.languagesNotInstalled))
        #expect(translator.request?.target?.maximalIdentifier == "en-Latn-US")
    }

    @Test func olderMacOSCantTranslate() {
        let translator = makeTranslator(engine: nil)

        translator.translate("Hello")

        #expect(!translator.isAvailable)
        #expect(translator.request?.outcome == .failed(.needsNewerMacOS))
    }

    @Test func engineFailureIsShown() async {
        struct Broken: Error {}
        let translator = makeTranslator(engine: .fake { _, _, _ in throw Broken() })

        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        #expect(translator.request?.outcome == .failed(.failed))
    }

    @Test func aNewerCopyReplacesTheOneOnItsWay() async {
        let translator = makeTranslator()

        translator.translate("Good morning, how are you today?")
        translator.translate("Доброе утро, как у тебя дела?")
        await translator.task?.value

        #expect(translator.request?.text == "Доброе утро, как у тебя дела?")
        #expect(translator.request?.outcome == .translated("en: Доброе утро, как у тебя дела?"))
    }

    @Test func longTextsAreCut() async {
        let translator = makeTranslator()

        translator.translate(String(repeating: "word ", count: 2_000))

        #expect(translator.request?.text.count == Translator.maxLength)
        await translator.task?.value
    }

    @Test func copyingPutsTheTranslationOnThePasteboard() async {
        let translator = makeTranslator()
        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        translator.copyTranslation()

        #expect(pasteboard.string(forType: .string) == "ru: Good morning, how are you today?")
    }

    @Test func typedTextIsTranslatedOnceTypingPauses() async {
        let calls = Calls()
        let translator = makeTranslator(engine: .fake { text, _, target in
            await calls.add(text)
            return "\(target.minimalIdentifier): \(text)"
        })

        translator.input = "Good"
        translator.inputDidChange()
        translator.input = "Good morning, how are you today?"
        translator.inputDidChange()
        #expect(translator.request == nil)
        await translator.task?.value

        #expect(translator.request?.outcome == .translated("ru: Good morning, how are you today?"))
        #expect(await calls.texts == ["Good morning, how are you today?"])
    }

    @Test func returnTranslatesWithoutWaiting() {
        let translator = makeTranslator()

        translator.input = "Good morning, how are you today?"
        translator.translateNow()

        #expect(translator.request?.outcome == .translating)
    }

    @Test func clearingTheFieldClearsTheTranslation() async {
        let translator = makeTranslator()
        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        translator.input = "  \n"
        translator.inputDidChange()

        #expect(translator.request == nil)
        #expect(translator.task == nil)
    }

    /// Typing on shouldn't make the translation blink away while the next one is on its way.
    @Test func translationStaysWhileTheNextIsOnItsWay() async {
        let translator = makeTranslator()
        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        translator.input = "Good evening, how are you today?"
        translator.translateNow()

        #expect(translator.request?.outcome == .translating)
        #expect(translator.request?.previous == "ru: Good morning, how are you today?")
        #expect(translator.request?.target?.maximalIdentifier == "ru-Cyrl-RU")
        await translator.task?.value
        #expect(translator.request?.translation == "ru: Good evening, how are you today?")
    }

    @Test func spacesAloneDontTranslateAgain() async {
        let calls = Calls()
        let translator = makeTranslator(engine: .fake { text, _, _ in
            await calls.add(text)
            return text
        })
        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        translator.input += " "
        translator.inputDidChange()
        await translator.task?.value

        #expect(await calls.texts.count == 1)
        #expect(translator.request?.translation == "Good morning, how are you today?")
    }

    /// The panel asks to try again after a failure, so asking again for the same text does.
    @Test func aFailedTranslationIsTriedAgain() async {
        struct Broken: Error {}
        let calls = Calls()
        let translator = makeTranslator(engine: .fake { text, _, _ in
            await calls.add(text)
            if await calls.texts.count == 1 {
                throw Broken()
            }
            return text
        })
        translator.translate("Good morning, how are you today?")
        await translator.task?.value
        #expect(translator.request?.outcome == .failed(.failed))

        translator.translateNow()
        await translator.task?.value

        #expect(translator.request?.translation == "Good morning, how are you today?")
    }

    @Test func aNewLanguageTranslatesAgain() async {
        let translator = makeTranslator()
        translator.translate("Good morning, how are you today?")
        await translator.task?.value

        settings.translationTarget = Locale.Language(identifier: "de").maximalIdentifier
        translator.translateNow()
        await translator.task?.value

        #expect(translator.request?.translation == "de: Good morning, how are you today?")
    }
}
