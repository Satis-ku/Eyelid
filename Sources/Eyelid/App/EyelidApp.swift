import SwiftUI

@main
struct EyelidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Eyelid", systemImage: "eye") {
            MenuBarMenu(settings: appDelegate.settings)
        }

        Settings {
            SettingsView(
                settings: appDelegate.settings,
                shelf: appDelegate.shelf,
                clipboard: appDelegate.clipboard,
                clipboardShortcut: appDelegate.clipboardShortcut,
                lidShortcut: appDelegate.lidShortcut,
                translator: appDelegate.translator,
                translationShortcut: appDelegate.translationShortcut
            )
        }
    }
}

/// Eyelid has no Dock icon, so the menu bar item is the way to reach Settings and to quit.
private struct MenuBarMenu: View {
    @Bindable var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The shortcut does the same, and Settings shows which it is.
        Button(settings.isLiveActivityHidden ? "Show Live Activity" : "Hide Live Activity") {
            settings.isLiveActivityHidden.toggle()
        }

        Divider()

        Button("Settings…") {
            // Without a Dock icon the app is never active on its own, and Settings would open behind other windows.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Support Eyelid…") {
            NSWorkspace.shared.open(Support.url)
        }

        Divider()

        Button("Quit Eyelid") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
