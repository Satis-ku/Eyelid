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
                Toggle(isOn: $settings.translatesOnDoubleCopy) {
                    Text("Translate with ⌘C ⌘C")
                    Text("Copy text twice in a row, and the notch shows it translated.")
                }

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
            } footer: {
                Text("Apple's Translation translates on this Mac, with the languages downloaded in System Settings → General → Language & Region → Translation Languages. Nothing is sent anywhere.")
            }
            .disabled(!translator.isAvailable)

            Section {
                Toggle(isOn: $settings.translationShortcutEnabled) {
                    Text("Translate with a shortcut")
                    Text("Translates what's copied already.")
                }

                LabeledContent {
                    HotKeyRecorder(hotKey: $settings.translationHotKey, shortcut: shortcut)
                } label: {
                    Text("Shortcut")
                    if shortcut.isTaken {
                        Text("Another app already uses this shortcut. Choose a different one.")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!settings.translationShortcutEnabled)
            }
            .disabled(!translator.isAvailable)

            if settings.translatesOnDoubleCopy || settings.translationShortcutEnabled, let access, access != .allowed {
                Section {
                    LabeledContent {
                        Button("Open Privacy & Security") {
                            NSWorkspace.shared.open(ClipboardSettings.pasteboardPrivacySettings)
                        }
                    } label: {
                        Text("Allow Eyelid to read what you copy")
                        Text("Otherwise macOS asks every time. Set Eyelid to Allow under Paste from Other Apps.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
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
