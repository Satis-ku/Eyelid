import SwiftUI

/// Which sections the dock at the bottom of the open notch holds, and the order of all of them.
struct SectionsSettings: View {
    @Bindable var settings: AppSettings
    let canTranslate: Bool
    /// The row a dragged section is over, which it takes the place of when dropped.
    @State private var dropTarget: NotchSection?

    var body: some View {
        Form {
            Section {
                ForEach(settings.sectionOrder, id: \.self) { section in
                    row(section)
                }
            } header: {
                Text("In the dock")
            } footer: {
                Text("Sections turned on here are in the dock at the bottom of the open notch, and every section is in the menu under the section's name beside the camera. Drag a section onto another to move it there.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ section: NotchSection) -> some View {
        let note = note(for: section)
        // A section that can't show isn't in the dock either. It's back there once it can.
        let isPinned = settings.pinnedSections.contains(section) && note == nil
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
                if let note {
                    Text(note)
                } else if !isPinned, isFull {
                    Text("The dock is full. Turn a section off to make room.")
                }
            }
            .disabled(note != nil || (!isPinned && isFull))
        }
        .contentShape(Rectangle())
        // Without a drag, as with VoiceOver.
        .accessibilityActions {
            if let index = settings.sectionOrder.firstIndex(of: section) {
                if index > 0 {
                    Button("Move Up") { settings.moveSection(section, to: settings.sectionOrder[index - 1]) }
                }
                if index < settings.sectionOrder.count - 1 {
                    Button("Move Down") { settings.moveSection(section, to: settings.sectionOrder[index + 1]) }
                }
            }
        }
        // Plain views drag inside a form, where a list's own reordering doesn't.
        .draggable(section.rawValue) {
            Label(section.title, systemImage: section.systemImage)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(NotchSection.init(rawValue:)) else { return false }
            settings.moveSection(dragged, to: section)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTarget = section
            } else if dropTarget == section {
                dropTarget = nil
            }
        }
        .overlay {
            if dropTarget == section {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
            }
        }
        .animation(.easeOut(duration: 0.15), value: settings.sectionOrder)
    }

    /// Why a section doesn't show at all, if it doesn't.
    private func note(for section: NotchSection) -> String? {
        switch section {
        case .shelf where !settings.shelfEnabled: "Off: turn the shelf on in Shelf."
        case .clipboard where !settings.clipboardEnabled: "Off: turn the history on in Clipboard."
        case .translation where !canTranslate: "Needs macOS 26 or later."
        default: nil
        }
    }
}
