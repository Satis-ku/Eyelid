import SwiftUI

struct TranslationSettings: View {
    @Bindable var settings: AppSettings
    let translator: Translator
    let shortcut: Shortcut
    @State private var languages: [Locale.Language] = []
    /// Changes in System Settings, outside the app, so it's checked again every few seconds.
    @State private var access: ClipboardHistory.Access?

    var body: some View {
        Form {
            if !translator.isAvailable {
                Section {
                    Text("Translating in the notch needs macOS 26 or later.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: $settings.translationShortcutEnabled) {
                    Text("Open the translator with a shortcut")
                    Text("Opens the translator in the notch, ready to type or paste text. Escape closes it.")
                }

                LabeledContent {
                    HotKeyRecorder(hotKey: $settings.translationHotKey, shortcut: shortcut)
                } label: {
                    Text("Shortcut")
                    if let problem = shortcut.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!settings.translationShortcutEnabled)
            }
            .disabled(!translator.isAvailable)

            Section {
                Toggle(isOn: $settings.translatesOnDoubleCopy) {
                    Text("Translate with ⌘C ⌘C")
                    Text("Copy text twice in a row, anywhere, and the notch shows it translated.")
                }
            }
            .disabled(!translator.isAvailable)

            Section {
                Picker(selection: $settings.translationTarget) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(languages, id: \.maximalIdentifier) { language in
                        Text(TranslationLanguages.fullName(of: language)).tag(String?.some(language.maximalIdentifier))
                    }
                } label: {
                    Text("Translate into")
                    Text("Automatic picks your first language in Language & Region, or your next one for text already in it.")
                }
                .onChange(of: settings.translationTarget) {
                    // What the notch shows comes in the new language.
                    translator.translateNow()
                }
            } footer: {
                Text("Apple's Translation translates on this Mac, with the languages downloaded in System Settings → General → Language & Region → Translation Languages. Nothing is sent anywhere.")
            }
            .disabled(!translator.isAvailable)

            if settings.translatesOnDoubleCopy, let access, access != .allowed {
                PasteAccessSection(explanation: "Otherwise macOS asks every time. Set Eyelid to Allow under Paste from Other Apps.")
            }
        }
        .formStyle(.grouped)
        .task {
            languages = await translator.supportedLanguages()
        }
        .task {
            while !Task.isCancelled {
                access = ClipboardHistory.Access(.general)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
