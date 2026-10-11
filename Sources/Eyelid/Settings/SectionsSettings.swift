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
            } footer: {
                Text("Drag a section onto another to move it there. The dock at the bottom of the open notch holds up to \(NotchSection.maxPinned), and every section is in the menu under the section's name beside the camera.")
            }
        }
        .formStyle(.grouped)
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
        .contentShape(Rectangle())
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
