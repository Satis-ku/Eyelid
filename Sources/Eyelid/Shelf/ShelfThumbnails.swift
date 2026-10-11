import AppKit
import QuickLookThumbnailing

/// Finder-style previews of the files on the shelf, made by Quick Look in its own sandboxed process.
@MainActor
enum ShelfThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    /// The thumbnail if there is one already, otherwise the file's icon.
    static func image(for url: URL) -> NSImage {
        cache.object(forKey: url as NSURL) ?? NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    /// Makes a thumbnail of the file's content, or returns nil if Quick Look has nothing better than the icon.
    static func load(for url: URL, side: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .all
        )
        // Draws documents and images the way Finder does, with a page outline or a border.
        request.iconMode = true

        guard let cgImage = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else {
            return nil
        }

        // Quick Look keeps the file's aspect ratio, so the thumbnail isn't always square.
        let image = NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
