import AppKit
import Foundation
import Testing
@testable import Eyelid

@MainActor
@Suite("File shelf")
final class ShelfTests {
    /// A folder of its own for each test, deleted when the test ends.
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "EyelidShelfTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? folder).appending(path: name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func makeShelf(store: InMemorySettingsStore = InMemorySettingsStore()) -> Shelf {
        Shelf(store: store, promisedFilesDirectory: folder.appending(path: "Promised", directoryHint: .isDirectory))
    }

    private func paths(_ shelf: Shelf) -> [String] {
        shelf.items.map { $0.url.resolvingSymlinksInPath().path(percentEncoded: false) }
    }

    private func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    @Test func addsFilesOnce() throws {
        let shelf = makeShelf()
        let first = try makeFile("first.txt")
        let second = try makeFile("second.txt")

        shelf.add([first, second, first])
        shelf.add([first])

        #expect(paths(shelf) == [path(first), path(second)])
    }

    @Test func takesOnlyFiles() {
        let shelf = makeShelf()

        shelf.add([URL(string: "https://example.com/file.zip")!])

        #expect(shelf.items.isEmpty)
    }

    @Test func keepsFilesAcrossARelaunch() throws {
        let store = InMemorySettingsStore()
        let shelf = makeShelf(store: store)
        shelf.add([try makeFile("kept.txt")])

        let relaunched = makeShelf(store: store)

        #expect(relaunched.items.map(\.id) == shelf.items.map(\.id))
        #expect(paths(relaunched) == paths(shelf))
    }

    @Test func followsAFileThatWasRenamed() throws {
        let shelf = makeShelf()
        let original = try makeFile("before.txt")
        shelf.add([original])
        let renamed = folder.appending(path: "after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        shelf.refresh()

        #expect(paths(shelf) == [path(renamed)])
    }

    @Test func forgetsAFileThatWasDeleted() throws {
        let store = InMemorySettingsStore()
        let shelf = makeShelf(store: store)
        let file = try makeFile("gone.txt")
        shelf.add([file, try makeFile("still-here.txt")])
        try FileManager.default.removeItem(at: file)

        shelf.refresh()

        #expect(shelf.items.count == 1)
        #expect(makeShelf(store: store).items.count == 1)
    }

    @Test func keepsOnlyTheLatestFiles() throws {
        let shelf = makeShelf()
        let files = try (0...Shelf.maxItems).map { try makeFile("\($0).txt") }

        shelf.add(files)

        #expect(shelf.items.count == Shelf.maxItems)
        #expect(paths(shelf).first == path(files[1]))
        #expect(paths(shelf).last == path(files[Shelf.maxItems]))
    }

    @Test func removesOneFileOrAll() throws {
        let shelf = makeShelf()
        shelf.add([try makeFile("a.txt"), try makeFile("b.txt"), try makeFile("c.txt")])

        shelf.remove(shelf.items[1].id)
        #expect(shelf.items.count == 2)

        shelf.removeAll()
        #expect(shelf.items.isEmpty)
    }

    @Test func removingAFileLeavesItOnDisk() throws {
        let shelf = makeShelf()
        let file = try makeFile("keep-me.txt")
        shelf.add([file])

        shelf.removeAll()

        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func deletesOnlyPromisedFilesThatLeftTheShelf() throws {
        let store = InMemorySettingsStore()
        let shelf = makeShelf(store: store)
        let onShelf = try shelf.makePromisedFilesFolder()
        shelf.add([try makeFile("photo.jpg", in: onShelf)])
        let removed = try shelf.makePromisedFilesFolder()
        _ = try makeFile("mail-attachment.pdf", in: removed)

        // As at launch: the items come from their bookmarks.
        makeShelf(store: store).deleteUnusedPromisedFiles()

        #expect(FileManager.default.fileExists(atPath: onShelf.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: removed.path(percentEncoded: false)))
    }

    @Test func eachDropGetsItsOwnFolder() throws {
        let shelf = makeShelf()

        let first = try shelf.makePromisedFilesFolder()
        let second = try shelf.makePromisedFilesFolder()

        #expect(first != second)
        #expect(first.deletingLastPathComponent() == shelf.promisedFilesDirectory)
    }
}

@MainActor
@Suite("Dropping on the shelf")
struct ShelfDropTests {
    @Test func filesAndPromisedFilesCount() {
        #expect(ShelfDrop.carriesFiles([.fileURL]))
        #expect(ShelfDrop.carriesFiles([.string, .fileURL]))
        #expect(ShelfDrop.carriesFiles(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }))
    }

    @Test func textAndLinksDoNot() {
        #expect(!ShelfDrop.carriesFiles([.string, .URL, .html]))
        #expect(!ShelfDrop.carriesFiles([]))
        #expect(!ShelfDrop.carriesFiles(nil))
    }

    /// AppKit reports promised files, as VS Code hands over every file, on a background queue. That used to crash.
    @Test func promisedFileWrittenOffTheMainThreadReachesTheShelf() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EyelidPromised-\(UUID().uuidString).py")
        try Data("print(1)".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let shelf = Shelf(store: InMemorySettingsStore(), promisedFilesDirectory: FileManager.default.temporaryDirectory)
        let handler = ShelfDrop.promisedFileHandler(for: shelf)

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                handler(file, nil)
                continuation.resume()
            }
        }
        for _ in 0..<200 where shelf.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(shelf.items.map { $0.url.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
    }

    @Test func dropAddsTheFilesButNotTheLinks() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EyelidDrop-\(UUID().uuidString).txt")
        try Data("dropped".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, URL(string: "https://example.com")! as NSURL])
        let shelf = Shelf(store: InMemorySettingsStore(), promisedFilesDirectory: FileManager.default.temporaryDirectory)

        #expect(ShelfDrop.receive(pasteboard, into: shelf))

        #expect(shelf.items.map { $0.url.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
    }
}
