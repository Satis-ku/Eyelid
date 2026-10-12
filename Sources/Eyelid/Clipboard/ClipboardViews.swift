import SwiftUI

/// The clipboard history in the open notch: a compact list, pinned copies first, then the newest.
struct ClipboardView: View {
    let model: NotchViewModel

    var body: some View {
        let entries = model.visibleClipboardEntries

        VStack(spacing: 6) {
            if !model.clipboardQuery.isEmpty {
                ClipboardSearchBar(query: model.clipboardQuery, matches: entries.count)
            }

            if model.showsClipboardPreview, let entry = model.selectedClipboardEntry {
                ClipboardPreview(entry: entry)
            } else if model.clipboard.entries.isEmpty {
                ClipboardPlaceholder(message: Self.emptyMessage(for: model.clipboard.access))
            } else if entries.isEmpty {
                ClipboardPlaceholder(message: "No copies match “\(model.clipboardQuery)”.")
            } else {
                ClipboardList(model: model, entries: entries)
            }

            if model.isHeldOpen {
                Text(model.showsClipboardPreview
                     ? "↑↓ next copy  ·  ↩ copy  ·  space or ⎋ back to the list"
                     : "Type to search  ·  ↩ copy  ·  space preview  ·  ⌘P pin  ·  ⌘⌫ remove")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private static func emptyMessage(for access: ClipboardHistory.Access) -> String {
        switch access {
        case .allowed:
            "What you copy shows up here."
        case .ask, .denied, .notAskedYet:
            "Allow Eyelid in System Settings → Privacy & Security → Paste from Other Apps to keep what you copy."
        }
    }
}

private struct ClipboardList: View {
    let model: NotchViewModel
    let entries: [ClipboardEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            model.choose(entry)
                        } label: {
                            ClipboardRow(entry: entry, isSelected: index == model.clipboardSelection)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy") { model.choose(entry) }
                            Button(entry.isPinned ? "Unpin" : "Pin") {
                                model.clipboard.setPinned(entry.id, !entry.isPinned)
                            }
                            Divider()
                            Button("Remove") { model.clipboard.remove(entry.id) }
                        }
                        .id(entry.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.clipboardSelection) { _, selection in
                guard entries.indices.contains(selection) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(entries[selection].id)
                }
            }
        }
    }
}

private struct ClipboardSearchBar: View {
    let query: String
    let matches: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
            Text(query)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text(matches == 1 ? "1 copy" : "\(matches) copies")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClipboardIcon(entry: entry)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    // Long copies stay compact. The selected one shows a little more of itself.
                    .lineLimit(isSelected ? 4 : 2)
                    .truncationMode(entry.kind == .files ? .middle : .tail)
                    .multilineTextAlignment(.leading)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 0)

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// The selected copy in full: all of a text in a scroll view, an image as large as it fits, or every file.
private struct ClipboardPreview: View {
    let entry: ClipboardEntry

    /// Laying out more text than this at once makes the notch stutter.
    private static let maxCharacters = 50_000

    var body: some View {
        Group {
            switch entry.kind {
            case .text:
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            case .image:
                ClipboardImagePreview(entry: entry)
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.fileURLs, id: \.self) { url in
                            HStack(spacing: 8) {
                                ClipboardFileIcon(path: url.path(percentEncoded: false), points: 20)
                                    .frame(width: 20, height: 20)
                                Text(url.path(percentEncoded: false))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var text: String {
        let text = entry.searchText
        guard text.count > Self.maxCharacters else { return text }
        return text.prefix(Self.maxCharacters) + "\n…"
    }
}

/// An image's thumbnail, a file's icon, or the icon of the app the text came from.
private struct ClipboardIcon: View {
    let entry: ClipboardEntry

    var body: some View {
        Group {
            if let thumbnail = entry.thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if let file = entry.fileURLs.first {
                ClipboardFileIcon(path: file.path(percentEncoded: false), points: 24)
            } else if let app = entry.sourceAppURL {
                ClipboardFileIcon(path: app.path(percentEncoded: false), points: 24)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct ClipboardPlaceholder: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 20, weight: .medium))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// A file's or an app's icon, in standard range, and looked up once rather than on every redraw.
private struct ClipboardFileIcon: View {
    let path: String
    let points: Int

    var body: some View {
        if let icon = StandardRangeIcons.icon(forFile: path, points: points) {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "doc")
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// A copied image, as large as it fits. It's scaled down once, away from the main thread, and only if its size is
/// sensible: anything can be on the pasteboard.
private struct ClipboardImagePreview: View {
    let entry: ClipboardEntry
    @State private var image: DecodedImage?

    /// The preview is about 430 pt wide at most, so this covers Retina screens.
    private static let maxPixelSize = 1_000

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.id) {
            let data = entry.items.first.flatMap { $0[.png] ?? $0[.tiff] }
            let maxPixelSize = Self.maxPixelSize
            image = await Task.detached(priority: .userInitiated) {
                data.flatMap { DecodedImage(data: $0, maxPixelSize: maxPixelSize) }
            }.value
        }
    }
}

/// An image decoded and scaled down. Immutable, so safe to hand between threads.
private struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage

    init?(data: Data, maxPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              Artwork.isAcceptable(width: width, height: height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        cgImage = image
    }
}
