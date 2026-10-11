import AppKit
import Testing
@testable import Eyelid

@Suite("Clipboard entries")
struct ClipboardEntryTests {
    private func png(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        image.addRepresentation(rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func textOnOneLine() throws {
        let entry = try #require(ClipboardEntry(items: [[.string: Data("  Hello,\n\n   world  ".utf8)]]))

        #expect(entry.kind == .text)
        #expect(entry.title == "Hello, world")
        #expect(entry.detail == nil)
    }

    @Test func longTextStaysShort() throws {
        let line = String(repeating: "word ", count: 40)
        let text = Array(repeating: line, count: 500).joined(separator: "\n")

        let entry = try #require(ClipboardEntry(items: [[.string: Data(text.utf8)]]))

        #expect(entry.title.count == ClipboardEntry.previewLength)
        #expect(entry.detail == "500 lines")
    }

    @Test func longSingleLineCountsCharacters() {
        #expect(ClipboardEntry.detail(of: String(repeating: "a", count: 2_431)) == 2_431.formatted() + " characters")
        #expect(ClipboardEntry.detail(of: "short") == nil)
        #expect(ClipboardEntry.detail(of: "two\nlines") == nil)
    }

    @Test func filesComeBeforeTheirNames() throws {
        let first = URL(filePath: "/tmp/Report.pdf")
        let second = URL(filePath: "/tmp/Photo.jpg")

        let entry = try #require(ClipboardEntry(items: [
            [.fileURL: first.dataRepresentation, .string: Data("Report.pdf".utf8)],
            [.fileURL: second.dataRepresentation, .string: Data("Photo.jpg".utf8)],
        ]))

        #expect(entry.kind == .files)
        #expect(entry.fileURLs == [first, second])
        #expect(entry.detail == "2 files")
    }

    @Test func imagesShowTheirSize() throws {
        let entry = try #require(ClipboardEntry(items: [[.png: try png(width: 640, height: 480)]]))

        #expect(entry.kind == .image)
        #expect(entry.detail == "640 × 480")
        #expect(entry.thumbnail != nil)
    }

    @Test func nothingToShowIsNoEntry() {
        #expect(ClipboardEntry(items: []) == nil)
        #expect(ClipboardEntry(items: [[.string: Data("   \n ".utf8)]]) == nil)
        #expect(ClipboardEntry(items: [[.png: Data("not an image".utf8)]]) == nil)
    }
}

@MainActor
@Suite("Clipboard history")
struct ClipboardHistoryTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    private func copy(_ text: String, marker: NSPasteboard.PasteboardType? = nil) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let marker {
            item.setData(Data(), forType: marker)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func titles(_ history: ClipboardHistory) -> [String] {
        history.entries.map(\.title)
    }

    @Test func newestFirst() {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)

        copy("first")
        history.checkForChanges()
        copy("second")
        history.checkForChanges()

        #expect(titles(history) == ["second", "first"])
    }

    @Test func readsOnlyAfterAChange() {
        copy("already there")
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)

        history.checkForChanges()

        #expect(history.entries.isEmpty)
    }

    @Test func copyingAgainMovesItUp() {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        for text in ["a", "b", "a"] {
            copy(text)
            history.checkForChanges()
        }

        #expect(titles(history) == ["a", "b"])
    }

    @Test func leavesOutPasswordsAndTransientData() {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)

        copy("hunter2", marker: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        history.checkForChanges()
        copy("temporary", marker: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        history.checkForChanges()

        #expect(history.entries.isEmpty)
    }

    @Test func keepsTheLatestEntries() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)

        for index in 0...ClipboardHistory.maxEntries {
            history.add(try entry("\(index)"))
        }

        #expect(history.entries.count == ClipboardHistory.maxEntries)
        #expect(history.entries.first?.title == "\(ClipboardHistory.maxEntries)")
        #expect(history.entries.last?.title == "1")
    }

    @Test func choosingAnEntryPutsItBackAsItWas() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        let rich = try NSAttributedString(string: "bold").data(
            from: NSRange(location: 0, length: 4),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(rich, forType: .rtf)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        history.checkForChanges()
        copy("later")
        history.checkForChanges()

        history.copy(history.entries[1])

        #expect(pasteboard.string(forType: .string) == "bold")
        #expect(pasteboard.data(forType: .rtf) == rich)
        #expect(titles(history) == ["bold", "later"])
        // Eyelid's own copy isn't a new entry.
        history.checkForChanges()
        #expect(history.entries.count == 2)
    }

    @Test func removesOneOrAll() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        for text in ["a", "b", "c"] {
            history.add(try entry(text))
        }

        history.remove(history.entries[1].id)
        #expect(titles(history) == ["c", "a"])

        history.removeAll()
        #expect(history.entries.isEmpty)
    }

    private func entry(_ text: String) throws -> ClipboardEntry {
        try #require(ClipboardEntry(items: [[.string: Data(text.utf8)]]))
    }

    @Test func searchIgnoresCaseAndAccents() throws {
        let note = try entry("Café au lait at Noon")

        #expect(note.matches("cafe"))
        #expect(note.matches("NOON"))
        #expect(note.matches(""))
        #expect(!note.matches("tea"))
    }

    @Test func searchLooksAtAllOfALongText() throws {
        let text = String(repeating: "filler ", count: 1_000) + "needle"

        #expect(try entry(text).matches("needle"))
    }

    @Test func pinnedCopiesStayOnTop() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        for text in ["a", "b", "c"] {
            history.add(try entry(text))
        }

        history.setPinned(history.entries[2].id, true)
        history.add(try entry("d"))

        #expect(titles(history) == ["a", "d", "c", "b"])
        #expect(history.entries.first?.isPinned == true)
    }

    @Test func copyingAPinnedCopyAgainLeavesItPinned() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        history.add(try entry("pinned"))
        history.setPinned(history.entries[0].id, true)
        history.add(try entry("other"))

        history.add(try entry("pinned"))

        #expect(titles(history) == ["pinned", "other"])
        #expect(history.entries[0].isPinned)
    }

    @Test func pinnedCopiesDontCountTowardsTheLimitAndSurviveClearing() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        history.add(try entry("keep"))
        history.setPinned(history.entries[0].id, true)

        for index in 0..<ClipboardHistory.maxEntries + 5 {
            history.add(try entry("\(index)"))
        }
        #expect(history.entries.count == ClipboardHistory.maxEntries + 1)
        #expect(history.entries.first?.title == "keep")

        history.removeAll()
        #expect(titles(history) == ["keep"])
    }

    @Test func unpinningMovesACopyBackAmongTheOthers() throws {
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: nil)
        for text in ["a", "b"] {
            history.add(try entry(text))
        }
        history.setPinned(history.entries[1].id, true)

        history.setPinned(history.entries[0].id, false)

        #expect(titles(history) == ["a", "b"])
        #expect(history.pinnedCount == 0)
    }

    @Test func pinnedCopiesAreKeptAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EyelidPinned-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = ClipboardHistory(pasteboard: pasteboard, pinnedFile: file)
        history.add(try entry("forgotten"))
        history.add(try entry("remembered"))
        history.setPinned(history.entries[0].id, true)

        let relaunched = ClipboardHistory(pasteboard: pasteboard, pinnedFile: file)

        #expect(titles(relaunched) == ["remembered"])
        #expect(relaunched.entries.first?.isPinned == true)

        relaunched.remove(relaunched.entries[0].id)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }
}
