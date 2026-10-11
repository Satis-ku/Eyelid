import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Shelf")

/// A file kept on the shelf.
struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    /// Where the file is now. `Shelf.refresh()` follows it when it is renamed or moved.
    var url: URL
    /// Finds the file again after it is renamed or moved, and after a relaunch.
    var bookmark: Data

    var name: String {
        FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }
}

/// Files dropped on the notch, kept until they are dragged out or removed.
///
/// The shelf keeps references, so the files stay where they are. The exception is files that apps hand over only
/// on drop, such as photos from Photos or images from Safari: those are written to `promisedFilesDirectory`.
@MainActor
@Observable
final class Shelf {
    /// More files than fit in a row are hard to find, and each one is a bookmark in the preferences.
    static let maxItems = 50

    private(set) var items: [ShelfItem] = []

    /// Where files that apps promise on drop are written, one subfolder per drop.
    @ObservationIgnored let promisedFilesDirectory: URL
    @ObservationIgnored private let store: any SettingsStore
    /// Whether a disk is connected, by where it's mounted. Tests stand in for it.
    @ObservationIgnored private let isMounted: (URL) -> Bool
    private static let storeKey = "shelfItems"

    init(
        store: any SettingsStore = UserDefaults.standard,
        promisedFilesDirectory: URL = Shelf.defaultPromisedFilesDirectory,
        isMounted: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) {
        self.store = store
        self.promisedFilesDirectory = promisedFilesDirectory
        self.isMounted = isMounted
        items = Self.load(from: store)
        // Resolving the bookmarks finds files that were moved, renamed or deleted while Eyelid wasn't running.
        refresh()
    }

    static var defaultPromisedFilesDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "io.github.satis-ku.eyelid/Shelf", directoryHint: .isDirectory)
    }

    // MARK: - Changes

    /// Adds files to the end of the shelf. Files already on it stay where they are.
    func add(_ urls: [URL]) {
        var added = false
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            guard !items.contains(where: { Self.isSameFile($0.url, url) }) else { continue }
            do {
                let bookmark = try url.bookmarkData()
                items.append(ShelfItem(id: UUID(), url: url, bookmark: bookmark))
                added = true
            } catch {
                logger.error("No bookmark for a dropped file: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard added else { return }
        if items.count > Self.maxItems {
            items.removeFirst(items.count - Self.maxItems)
        }
        save()
    }

    func remove(_ id: ShelfItem.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    /// Follows files that were renamed or moved, and forgets the ones that were deleted or moved to the Trash. Files
    /// on a disk that isn't connected are kept for when it is.
    func refresh() {
        let refreshed = items.compactMap(resolve)
        guard refreshed != items else { return }
        items = refreshed
        save()
    }

    private func resolve(_ item: ShelfItem) -> ShelfItem? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &isStale
        ) else {
            // The bookmark still knows the disk the file was on.
            let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: item.bookmark)?.volume
            return volume.map(isMounted) == false ? item : nil
        }

        let resolved = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)), !Self.isInTrash(resolved) else {
            return nil
        }

        var item = item
        item.url = resolved
        if isStale, let bookmark = try? resolved.bookmarkData() {
            item.bookmark = bookmark
        }
        return item
    }

    private static func isInTrash(_ url: URL) -> Bool {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
        else { return false }
        let trashPath = trash.standardizedFileURL.path(percentEncoded: false)
        return url.path(percentEncoded: false).hasPrefix(trashPath.hasSuffix("/") ? trashPath : trashPath + "/")
    }

    /// Compares file identities rather than paths, which can differ in case, in symbolic links or in a trailing slash.
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = (try? a.resourceValues(forKeys: key))?.fileResourceIdentifier as? NSObject,
              let second = (try? b.resourceValues(forKeys: key))?.fileResourceIdentifier
        else { return a == b }
        return first.isEqual(second)
    }

    // MARK: - Promised files

    /// A new, empty folder for the files of one drop, so files with the same name don't overwrite each other.
    func makePromisedFilesFolder() throws -> URL {
        let folder = promisedFilesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Deletes promised files that are no longer on the shelf.
    ///
    /// Runs at launch rather than when an item is removed: the app a file was just dragged to may still be reading it.
    func deleteUnusedPromisedFiles() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: promisedFilesDirectory, includingPropertiesForKeys: nil)
        else { return }

        let inUse = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        for folder in folders where !inUse.contains(folder.standardizedFileURL) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                logger.error("Could not delete unused promised files: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Storage

    private struct StoredItem: Codable {
        let id: UUID
        let bookmark: Data
    }

    private func save() {
        let stored = items.map { StoredItem(id: $0.id, bookmark: $0.bookmark) }
        store.set(try? PropertyListEncoder().encode(stored), forKey: Self.storeKey)
    }

    private static func load(from store: any SettingsStore) -> [ShelfItem] {
        guard let data = store.object(forKey: storeKey) as? Data,
              let stored = try? PropertyListDecoder().decode([StoredItem].self, from: data)
        else { return [] }
        // The URL is a placeholder until `refresh()` resolves the bookmark.
        return stored.map { ShelfItem(id: $0.id, url: URL(filePath: "/"), bookmark: $0.bookmark) }
    }
}
