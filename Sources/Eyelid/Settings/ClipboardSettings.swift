import SwiftUI

struct ClipboardSettings: View {
    @Bindable var settings: AppSettings
    let clipboard: ClipboardHistory
    let shortcut: Shortcut
    /// Changes in System Settings, outside the app, so it's checked again every few seconds.
    @State private var access: ClipboardHistory.Access?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.clipboardEnabled) {
                    Text("Clipboard history")
                    Text("Keeps the last \(ClipboardHistory.maxEntries) things you copy. The shortcut opens them in the notch, and choosing one copies it again.")
                }

                LabeledContent {
                    HotKeyRecorder(hotKey: $settings.clipboardHotKey, shortcut: shortcut)
                } label: {
                    Text("Shortcut")
                    if let problem = shortcut.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!settings.clipboardEnabled)

                Toggle(isOn: $settings.clipboardPastesAfterChoosing) {
                    Text("Paste right away")
                    Text("Choosing a copy also pastes it into the app you were in. Needs Accessibility access, like the volume and brightness HUD.")
                }
                .disabled(!settings.clipboardEnabled)
            } footer: {
                Text("The history stays in memory and is gone when Eyelid quits, except for pinned copies, which are saved on this Mac. Copies that password managers mark as concealed are left out.")
            }

            if settings.clipboardEnabled, let access, access != .allowed {
                PasteAccessSection(explanation: "macOS asks before an app reads what other apps copy. Set Eyelid to Allow under Paste from Other Apps, then quit and reopen Eyelid.")
            }

            Section {
                LabeledContent {
                    HStack {
                        Text(clipboard.entries.count, format: .number)
                            .monospacedDigit()
                        Button("Clear") {
                            clipboard.removeAll()
                        }
                        .disabled(clipboard.entries.count == clipboard.pinnedCount)
                    }
                } label: {
                    Text("In the history")
                    if clipboard.pinnedCount > 0 {
                        Text("\(clipboard.pinnedCount) pinned, which Clear keeps")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                access = clipboard.access
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

}

/// Asks to let Eyelid read what other apps copy, for the clipboard history and for translating a double copy.
struct PasteAccessSection: View {
    let explanation: String

    var body: some View {
        Section {
            LabeledContent {
                Button("Open Privacy & Security") {
                    NSWorkspace.shared.open(SystemSettingsPage.pasteFromOtherApps)
                }
            } label: {
                Text("Allow Eyelid to read what you copy")
                Text(explanation)
            }
        }
    }
}
