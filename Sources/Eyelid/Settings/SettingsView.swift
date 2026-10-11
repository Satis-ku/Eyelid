import SwiftUI

/// Tabs, like System Settings panes in other Mac apps, so no tab grows taller than the screen.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let shelf: Shelf
    let clipboard: ClipboardHistory
    let clipboardShortcut: Shortcut
    let lidShortcut: Shortcut
    let translator: Translator
    let translationShortcut: Shortcut

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotchSettings(settings: settings, shortcut: lidShortcut)
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            VolumeAndBrightnessSettings(settings: settings)
                .tabItem { Label("Volume & Brightness", systemImage: "speaker.wave.2") }
            BatterySettings(settings: settings)
                .tabItem { Label("Battery", systemImage: "battery.75percent") }
            ShelfSettings(settings: settings, shelf: shelf)
                .tabItem { Label("Shelf", systemImage: "tray") }
            ClipboardSettings(settings: settings, clipboard: clipboard, shortcut: clipboardShortcut)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            TranslationSettings(settings: settings, translator: translator, shortcut: translationShortcut)
                .tabItem { Label("Translation", systemImage: "translate") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }

    /// The width every tab shares, so the window doesn't jump sideways when switching tabs.
    static let width: CGFloat = 500
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()

                Picker(selection: $settings.notchDisplays) {
                    Text("Automatic").tag(NotchDisplays.automatic)
                    Text("All displays").tag(NotchDisplays.all)
                    Divider()
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = screen.displayID {
                            Text(screen.localizedName).tag(NotchDisplays.display(id))
                        }
                    }
                } label: {
                    Text("Display")
                    Text("Automatic follows the pointer from display to display. Displays without a notch get one drawn at the top.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}

private struct NotchSettings: View {
    @Bindable var settings: AppSettings
    let shortcut: Shortcut

    var body: some View {
        Form {
            Section {
                Picker("Open on hover", selection: $settings.openDelay) {
                    ForEach(AppSettings.openDelayOptions, id: \.self) { delay in
                        Text(Self.label(forDelay: delay)).tag(delay)
                    }
                }

                Toggle(isOn: $settings.hapticsEnabled) {
                    Text("Haptic feedback when opening")
                    // macOS drops the feedback otherwise, which is easy to hit with an open delay.
                    Text("Plays only while your finger is on the trackpad.")
                }

                Toggle(isOn: $settings.showsLiveActivity) {
                    Text("Live activity")
                    Text("Shows the artwork and an equalizer next to the notch while something plays.")
                }

                Toggle(isOn: $settings.equalizerFollowsAudio) {
                    Text("Equalizer follows the sound")
                    Text(AudioLevels.isSupported
                        ? "macOS asks to allow Eyelid to record system audio, and shows the recording indicator while it listens. Eyelid only measures how loud each pitch is, and keeps nothing."
                        : "Needs macOS 14.2 or later.")
                }
                .disabled(!AudioLevels.isSupported || !settings.showsLiveActivity)

                Toggle(isOn: $settings.showsClockWhenIdle) {
                    Text("Clock when nothing plays")
                    Text("Shows the time and the battery next to the notch, so you can hide them from the menu bar.")
                }

                Toggle(isOn: $settings.showsDateInOpenNotch) {
                    Text("Date and time in the open notch")
                    Text("Next to the battery.")
                }

                Toggle(isOn: $settings.showsTrackTitle) {
                    Text("Track title")
                    Text("Shows the title under the notch when something starts playing, in the colors of its artwork.")
                }
            }

            Section {
                Toggle(isOn: $settings.liveActivityShortcutEnabled) {
                    Text("Hide and show with a shortcut")
                    Text("Hides the live activity and track titles, so the notch covers nothing in the menu bar. Volume, battery and output changes still show.")
                }

                LabeledContent {
                    HotKeyRecorder(hotKey: $settings.liveActivityHotKey, shortcut: shortcut)
                } label: {
                    Text("Shortcut")
                    if shortcut.isTaken {
                        Text("Another app already uses this shortcut. Choose a different one.")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!settings.liveActivityShortcutEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }

    private static func label(forDelay delay: TimeInterval) -> String {
        delay == 0 ? "Instantly" : "After \(delay.formatted()) s"
    }
}

private struct VolumeAndBrightnessSettings: View {
    @Bindable var settings: AppSettings
    @State private var devices = OutputDevice.all()

    /// Rows that fit on a 14-inch screen along with the rest of the tab.
    private static let maxDevicesWithoutScrolling = 5

    private var scrolls: Bool {
        devices.count > Self.maxDevicesWithoutScrolling
    }

    var body: some View {
        Form {
            Section {
                SystemHUDSettings(settings: settings)
            }

            Section {
                Toggle(isOn: $settings.outputActivityEnabled) {
                    Text("Output changes")
                    Text("When sound switches to other speakers or headphones, shows them next to the notch: AirPods and Beats with their charge and the earbuds in use, others with their volume.")
                }
            }

            if settings.replacesSystemHUD || settings.outputActivityEnabled {
                Section {
                    OutputDeviceIconSettings(settings: settings, devices: devices)
                } header: {
                    Text("Output devices")
                } footer: {
                    Text("The icon the notch shows for each device. macOS knows AirPods and Beats, but other Bluetooth devices all look like headphones to it.")
                }
            }
        }
        .formStyle(.grouped)
        // Fits the content, unless a long device list would push the window off the screen: then it scrolls.
        .frame(width: SettingsView.width, height: scrolls ? 560 : nil)
        .fixedSize(horizontal: true, vertical: !scrolls)
        // On the Form, which always exists: on the list itself, this would run once per device, or never.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let current = OutputDevice.all()
                if current != devices {
                    devices = current
                }
            }
        }
    }
}

private struct BatterySettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.batteryActivityEnabled) {
                    Text("Battery activity")
                    Text("Shows the charge next to the notch when you plug in or unplug the charger, and when the battery drops to 20% and 10%.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}

private struct ShelfSettings: View {
    @Bindable var settings: AppSettings
    let shelf: Shelf

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.shelfEnabled) {
                    Text("File shelf")
                    Text("Drop files on the notch to keep them at hand, then drag them out wherever you need them. The files stay where they are.")
                }

                Toggle(isOn: $settings.shelfRemovesDraggedFiles) {
                    Text("Remove files once they are dragged out")
                    Text("Otherwise they stay on the shelf until you remove them.")
                }
                .disabled(!settings.shelfEnabled)
            }

            Section {
                LabeledContent("On the shelf") {
                    HStack {
                        Text(shelf.items.count, format: .number)
                            .monospacedDigit()
                        Button("Clear") {
                            shelf.removeAll()
                        }
                        .disabled(shelf.items.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Eyelid")
                            .font(.title2.weight(.semibold))
                        Text("An open-source, Dynamic Island–style notch for your MacBook.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("License", value: "GNU GPL v3")
                Link("Source code on GitHub", destination: URL(string: "https://github.com/Satis-ku/Eyelid")!)
            }

            Section {
                LabeledContent {
                    Link("Support Eyelid", destination: Support.url)
                } label: {
                    Text("Eyelid is free and open source")
                    Text("If it's useful to you, you can support its development.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }

    /// "1.2.3 (45)": builds made after the same tag differ only in the build number.
    private static var version: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return "development build" }
        return "\(version) (\(build))"
    }
}
