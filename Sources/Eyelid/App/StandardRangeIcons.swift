import AppKit

/// App and file icons as the notch draws them: plain 8-bit sRGB copies. Icons on recent macOS are 16-bit
/// extended-range images, and a single one of them switches SwiftUI to HDR rendering for the whole notch. Each is
/// drawn once and kept, since looking an icon up and drawing it takes a moment.
@MainActor
enum StandardRangeIcons {
    private static let cache = NSCache<NSString, NSImage>()

    /// The icon of the file, folder or app at `path`, for showing `points` wide.
    static func icon(forFile path: String, points: Int) -> NSImage? {
        let key = "\(points) \(path)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let icon = redraw(NSWorkspace.shared.icon(forFile: path), points: points) else { return nil }
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// `image` drawn into an 8-bit sRGB bitmap, at twice `points` for Retina displays.
    static func redraw(_ image: NSImage, points: Int) -> NSImage? {
        let pixels = points * 2
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: points, height: points)) }
    }
}
