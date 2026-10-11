import Foundation
import NaturalLanguage

/// Which language a text is in, and which to translate it into, among the languages Apple's Translation supports.
enum TranslationLanguages {
    /// The language NaturalLanguage knows `language` by: its code, with the script for Chinese.
    static func recognizerLanguage(for language: Locale.Language) -> NLLanguage? {
        let full = Locale.Language(identifier: language.maximalIdentifier)
        guard let code = full.languageCode?.identifier else { return nil }
        if code == "zh" {
            return full.script == .hanTraditional ? .traditionalChinese : .simplifiedChinese
        }
        return NLLanguage(rawValue: code)
    }

    /// The language of `text`, among `supported`, leaning towards the user's own languages. Short texts need that:
    /// on its own, "Привет" reads as Bulgarian and "OK" as Polish.
    static func detect(
        _ text: String,
        among supported: [Locale.Language],
        preferring preferred: [Locale.Language]
    ) -> Locale.Language? {
        let candidates = Set(supported.compactMap(recognizerLanguage))
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(candidates)
        // Every language stays possible, and the user's own are likelier. Leaving the others out of the hints would
        // make German read as English.
        var hints = Dictionary(uniqueKeysWithValues: candidates.map { ($0, 0.1) })
        hints[.english] = 0.5
        for language in preferred.compactMap(recognizerLanguage) where candidates.contains(language) {
            hints[language] = 1
        }
        recognizer.languageHints = hints
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return nil }
        return variant(of: detected, among: supported, preferring: preferred)
    }

    /// What to translate a text in `source` into: `chosen` if there is one, otherwise the user's first language. A text
    /// already in that language goes into the user's next one, or else into English.
    static func target(
        for source: Locale.Language,
        chosen: Locale.Language?,
        among supported: [Locale.Language],
        preferring preferred: [Locale.Language]
    ) -> Locale.Language? {
        let sourceLanguage = recognizerLanguage(for: source)
        let candidates = [chosen].compactMap(\.self) + preferred + [Locale.Language(identifier: "en")]
        for candidate in candidates {
            guard let language = recognizerLanguage(for: candidate), language != sourceLanguage else { continue }
            if let exact = supported.first(where: { $0.maximalIdentifier == candidate.maximalIdentifier }) {
                return exact
            }
            if let variant = variant(of: language, among: supported, preferring: preferred) {
                return variant
            }
        }
        return nil
    }

    /// The variant of `language` to use: the user's own, such as British English, or else the main one.
    static func variant(
        of language: NLLanguage,
        among supported: [Locale.Language],
        preferring preferred: [Locale.Language]
    ) -> Locale.Language? {
        let matching = supported.filter { recognizerLanguage(for: $0) == language }
        for own in preferred {
            if let exact = matching.first(where: { $0.maximalIdentifier == own.maximalIdentifier }) {
                return exact
            }
        }
        return matching.first { $0.minimalIdentifier == language.rawValue } ?? matching.first
    }

    /// The language's name, such as "English", without the region, which only matters for a few.
    static func name(of language: Locale.Language, in locale: Locale = .current) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    /// The name with the region or script where the language has more than one variant, as in a list to choose from.
    static func fullName(of language: Locale.Language, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: language.minimalIdentifier) ?? name(of: language, in: locale)
    }
}
