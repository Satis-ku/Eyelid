import SwiftUI

/// Which sections the dock at the bottom of the open notch holds, and the order of all of them.
struct SectionsSettings: View {
    @Bindable var settings: AppSettings
    let canTranslate: Bool

    var body: some View {
        Form {
            Section {
                ForEach(settings.sectionOrder, id: \.self) { section in
                    row(section)
                }
                .onMove { source, destination in
                    settings.moveSections(from: source, to: destination)
                }
            } footer: {
                Text("Drag sections to change their order. The dock at the bottom of the open notch holds up to \(NotchSection.maxPinned), and every section is in the menu under the section's name beside the camera.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        .fixedSize()
    }

    private func row(_ section: NotchSection) -> some View {
        let isPinned = settings.pinnedSections.contains(section)
        let isFull = settings.pinnedSections.count >= NotchSection.maxPinned
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Image(systemName: section.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(
                get: { isPinned },
                set: { settings.setPinned(section, $0) }
            )) {
                Text(section.title)
                if let note = note(for: section) {
                    Text(note)
                } else if !isPinned, isFull {
                    Text("The dock is full. Unpin a section to make room.")
                }
            }
            .disabled(!isPinned && isFull)
        }
    }

    /// Why a section doesn't show at all, if it doesn't.
    private func note(for section: NotchSection) -> String? {
        switch section {
        case .shelf where !settings.shelfEnabled: "Off: turn the shelf on in the Shelf tab."
        case .clipboard where !settings.clipboardEnabled: "Off: turn the history on in the Clipboard tab."
        case .translation where !canTranslate: "Needs macOS 26 or later."
        default: nil
        }
    }
}
