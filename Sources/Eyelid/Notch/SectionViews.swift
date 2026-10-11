import SwiftUI

/// The section the open notch shows, beside the camera. A click opens the menu of all sections, or puts it away.
struct SectionTitle: View {
    let section: NotchSection
    let systemImage: String
    let isMenuShown: Bool
    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isMenuShown ? 180 : 0))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.white.opacity(isMenuShown ? 0.14 : (isHovered ? 0.08 : 0)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.04))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(section.title)
        .accessibilityHint(isMenuShown ? "Hides all sections" : "Shows all sections")
        .animation(.easeOut(duration: 0.15), value: isMenuShown)
    }
}

/// The pinned sections along the bottom of the open notch, a click from each other.
struct SectionDock: View {
    let model: NotchViewModel

    var body: some View {
        let sections = model.dockSections
        VStack(spacing: 0) {
            if !sections.isEmpty {
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 0.5)
            }
            HStack(spacing: 0) {
                ForEach(sections, id: \.self) { section in
                    DockButton(
                        title: section.title,
                        systemImage: model.systemImage(for: section),
                        isSelected: !model.showsSectionMenu && model.currentSection == section
                    ) {
                        model.select(section)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            // Clear of the notch's rounded bottom corners.
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct DockButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 1 : (isHovered ? 0.85 : 0.45)))
                .frame(width: 40, height: 24)
                .background(.white.opacity(isSelected ? 0.14 : (isHovered ? 0.07 : 0)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.08))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

/// Every section there is, as tiles, in place of the current one.
struct SectionMenu: View {
    let model: NotchViewModel

    var body: some View {
        let spacing = NotchViewModel.Layout.sectionTileSpacing
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: spacing),
                count: NotchViewModel.Layout.sectionMenuColumns
            ),
            spacing: spacing
        ) {
            ForEach(model.sections, id: \.self) { section in
                SectionTile(
                    title: section.title,
                    systemImage: model.systemImage(for: section),
                    isCurrent: model.currentSection == section
                ) {
                    model.select(section)
                }
            }
        }
        // In the middle of the section, which is as tall as any other.
        .frame(maxHeight: .infinity)
    }
}

private struct SectionTile: View {
    let title: String
    let systemImage: String
    let isCurrent: Bool
    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(isCurrent || isHovered ? 1 : 0.8))
            .frame(maxWidth: .infinity)
            .frame(height: NotchViewModel.Layout.sectionTileHeight)
            .background(
                .white.opacity(isCurrent ? 0.2 : (isHovered ? 0.14 : 0.08)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1.04))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
    }
}
