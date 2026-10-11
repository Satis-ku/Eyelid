import SwiftUI

/// The shelf in the open notch: a row of files, or a place to drop them.
struct ShelfView: View {
    let model: NotchViewModel

    var body: some View {
        let shelf = model.shelf

        if shelf.items.isEmpty {
            DropPrompt(isTargeted: model.isDropTargeted)
        } else {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        if shelf.items.count > 1 {
                            AllFilesTile(items: shelf.items, shelf: shelf, dragSource: model.shelfDragSource)
                        }
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf, dragSource: model.shelfDragSource)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.never)

                VStack(spacing: 8) {
                    ShelfButton(title: "AirDrop All") {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.system(size: 10, weight: .bold))
                    } action: {
                        ShelfSharing.airDrop(shelf.items.map(\.url))
                    }

                    ShelfButton(title: "Clear Shelf") {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    } action: {
                        shelf.removeAll()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if model.isDropTargeted {
                    DropOutline(isTargeted: true)
                }
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: Shelf
    let dragSource: ShelfDragSource
    @State private var thumbnail: NSImage?

    private static let imageSide: CGFloat = 48
    private static let width: CGFloat = 70
    private static let padding: CGFloat = 4

    var body: some View {
        let image = thumbnail ?? ShelfThumbnails.image(for: item.url)

        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.imageSide, height: Self.imageSide)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .overlay {
            ShelfTileMouseArea(
                items: [item],
                image: image,
                imageFrame: CGRect(
                    x: (Self.width - Self.imageSide) / 2,
                    y: Self.padding,
                    width: Self.imageSide,
                    height: Self.imageSide
                ),
                shelf: shelf,
                dragSource: dragSource
            )
        }
        .task(id: item.url) {
            thumbnail = await ShelfThumbnails.load(for: item.url, side: Self.imageSide)
        }
    }
}

/// The first tile when there are several files: drags them all at once.
private struct AllFilesTile: View {
    let items: [ShelfItem]
    let shelf: Shelf
    let dragSource: ShelfDragSource

    private static let imageSide: CGFloat = 48
    private static let width: CGFloat = 70
    private static let padding: CGFloat = 4

    var body: some View {
        let images = items.prefix(3).map { ShelfThumbnails.image(for: $0.url) }

        VStack(spacing: 4) {
            ZStack {
                ForEach(Array(images.enumerated().reversed()), id: \.offset) { index, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.imageSide - 8, height: Self.imageSide - 8)
                        .rotationEffect(.degrees(Double(index) * 9 - 9))
                        .offset(x: CGFloat(index) * 4 - 4)
                }
            }
            .frame(width: Self.imageSide, height: Self.imageSide)
            Text("All \(items.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .overlay {
            if let first = images.first {
                ShelfTileMouseArea(
                    items: items,
                    isAll: true,
                    image: first,
                    imageFrame: CGRect(
                        x: (Self.width - Self.imageSide) / 2,
                        y: Self.padding,
                        width: Self.imageSide,
                        height: Self.imageSide
                    ),
                    shelf: shelf,
                    dragSource: dragSource
                )
            }
        }
        .accessibilityLabel("All \(items.count) files")
    }
}

/// A small round button beside the files.
private struct ShelfButton<Label: View>: View {
    let title: String
    @ViewBuilder let label: () -> Label
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}

/// Shown while the shelf is empty, and lights up while files are dragged over the notch.
private struct DropPrompt: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20, weight: .medium))
            Text(isTargeted ? "Drop to add to the shelf" : "Drop files here to keep them at hand")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DropOutline(isTargeted: isTargeted) }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

private struct DropOutline: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(isTargeted ? 0.08 : 0))
            .strokeBorder(
                .white.opacity(isTargeted ? 0.6 : 0.2),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
            )
    }
}
