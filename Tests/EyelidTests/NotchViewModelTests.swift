import AppKit
import Foundation
import Testing
@testable import Eyelid

@MainActor
@Suite("Notch layout")
final class NotchViewModelTests {
    /// Pasteboards made for the models, released as the test ends: named ones stay in the pasteboard server.
    private var pasteboards: [NSPasteboard] = []

    isolated deinit {
        pasteboards.forEach { $0.releaseGlobally() }
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    /// A 14-inch MacBook Pro: 1512×982 points with a 185×32 notch in the middle.
    private let geometry = NotchGeometry(
        notchSize: CGSize(width: 185, height: 32),
        notchMidX: 756,
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
    )

    private func makeModel(translation engine: TranslationEngine? = .fake()) -> NotchViewModel {
        let settings = AppSettings(defaults: InMemorySettingsStore())
        // Whether a player is heard can't be told here, so what plays is shown.
        let nowPlaying = NowPlayingService(isAudible: { _ in nil })
        return NotchViewModel(
            geometry: geometry,
            nowPlaying: nowPlaying,
            audioLevels: AudioLevels(settings: settings, nowPlaying: nowPlaying),
            battery: BatteryService(),
            shelf: Shelf(store: InMemorySettingsStore(), promisedFilesDirectory: FileManager.default.temporaryDirectory),
            clipboard: ClipboardHistory(pasteboard: pasteboard(), pinnedFile: nil),
            translator: Translator(settings: settings, engine: engine, pasteboard: pasteboard()),
            appVolumes: AppVolumes(defaults: InMemorySettingsStore(), apps: { [] }, output: { nil }, makeTap: { _ in nil }),
            settings: settings
        )
    }

    @Test func closedNotchMatchesTheHardwareNotch() {
        let model = makeModel()

        #expect(model.bodySize == CGSize(width: 185, height: 32))
        #expect(model.topRadius == NotchViewModel.Layout.closedTopRadius)
        #expect(model.bottomRadius == NotchViewModel.Layout.closedBottomRadius)
    }

    @Test func openNotchGrowsBelowTheHardwareNotch() {
        let model = makeModel()
        model.state = .open

        #expect(model.bodySize == CGSize(
            width: NotchViewModel.Layout.openWidth,
            height: 32 + NotchViewModel.Layout.openContentHeight + NotchViewModel.Layout.dockHeight
        ))
        #expect(model.topRadius == NotchViewModel.Layout.openTopRadius)
    }

    @Test func windowFitsTheOpenNotchAndItsShadow() {
        let model = makeModel()
        let window = model.windowSize
        model.state = .open
        let open = model.bodySize

        #expect(window.width >= open.width + 2 * model.topRadius)
        #expect(window.height > open.height)
    }

    @Test func noLiveActivityWithoutATrack() {
        #expect(!makeModel().showsActivity)
    }

    @Test func batteryEventWidensTheClosedNotch() {
        let model = makeModel()
        model.settings.showsLiveActivity = false

        model.batteryEvent = .pluggedIn(BatteryState(level: 80, isPluggedIn: true, isCharging: true))

        #expect(model.showsActivity)
        #expect(!model.showsNowPlayingActivity)
        #expect(model.bodySize.width == 185 + 2 * NotchViewModel.Layout.activitySideWidth)
    }

    @Test func hudTakesPrecedenceAndNeedsMoreRoom() {
        let model = makeModel()
        model.batteryEvent = .unplugged(BatteryState(level: 50, isPluggedIn: false, isCharging: false))

        model.hud = HUDEvent(kind: .volume, level: 0.5)

        #expect(model.showsActivity)
        #expect(model.bodySize.width == 185 + 2 * NotchViewModel.Layout.hudSideWidth)
    }

    @Test func trackTitleDropsTheClosedNotchLikeALowerEyelid() {
        let model = makeModel()

        model.trackTitle = TrackTitle()

        #expect(model.isShowingTrackTitle)
        #expect(model.bodySize == CGSize(
            width: 185 + 2 * NotchViewModel.Layout.activitySideWidth,
            height: 32 + NotchViewModel.Layout.trackTitleHeight
        ))
        #expect(model.lowerLidDepth == NotchViewModel.Layout.trackTitleHeight)
        #expect(model.bottomRadius == NotchViewModel.Layout.lidBottomRadius)
        // The text runs inside the lid, with room for its descenders.
        #expect(NotchViewModel.Layout.trackTitleInset >= 4)
        #expect(NotchViewModel.Layout.trackTitleInset + TrackTitle.fontSize < NotchViewModel.Layout.trackTitleHeight)
    }

    /// Switching sections in the dock leaves the pointer where it was, over the notch, so it stays open.
    @Test func everySectionIsAsTall() {
        let model = makeModel()
        model.state = .open
        model.settings.clipboardEnabled = true
        let height = 32 + NotchViewModel.Layout.openContentHeight + NotchViewModel.Layout.dockHeight

        for section in model.sections {
            model.select(section)
            #expect(model.bodySize.height == height)
        }
        model.showsSectionMenu = true
        #expect(model.bodySize.height == height)
        #expect(model.windowSize.height > height)
    }

    @Test func soundShowsAsManyOutputsAsFit() {
        let layout = NotchViewModel.Layout.self
        let rows = CGFloat(layout.soundMaxRows)

        #expect(layout.soundFixedHeight + rows * layout.soundRowHeight <= layout.openContentHeight)
        #expect(layout.soundFixedHeight + (rows + 1) * layout.soundRowHeight > layout.openContentHeight)
    }

    @Test func equalizerIsClickableOnlyWhileItShows() throws {
        let model = makeModel()
        #expect(model.equalizerRect == nil)

        let payload = try JSONDecoder().decode(
            AdapterStreamMessage.Payload.self,
            from: Data(#"{"title":"Song","playing":true}"#.utf8)
        )
        model.nowPlaying.apply(NowPlayingSnapshot(payload: payload))
        // Right of the camera, as tall as the notch.
        #expect(try #require(model.equalizerRect) == CGRect(
            x: 756 + 185 / 2,
            y: 982 - 32,
            width: NotchViewModel.Layout.activitySideWidth,
            height: 32
        ))

        model.hud = HUDEvent(kind: .volume, level: 0.5)
        #expect(model.equalizerRect == nil)
        model.hud = nil
        model.state = .open
        #expect(model.equalizerRect == nil)
    }

    @Test func statusFitsRightOfTheCamera() {
        let model = makeModel()

        #expect(model.statusWidth == (NotchViewModel.Layout.openWidth - 185) / 2 - NotchViewModel.Layout.openHorizontalPadding
            - NotchViewModel.Layout.cameraClearance)
        // Enough for "Oct 11 10:07" and the battery.
        #expect(model.statusWidth >= 115)
    }

    @Test func clockShowsBesideTheNotchWhileNothingPlays() {
        let model = makeModel()
        #expect(!model.showsIdleActivity)

        model.settings.showsClockWhenIdle = true

        #expect(model.showsIdleActivity)
        #expect(model.bodySize.width == 185 + 2 * NotchViewModel.Layout.activitySideWidth)

        // Events and hiding take it away.
        model.hud = HUDEvent(kind: .volume, level: 0.5)
        #expect(!model.showsIdleActivity)
        model.hud = nil
        model.settings.isLiveActivityHidden = true
        #expect(!model.showsIdleActivity)
        #expect(model.bodySize.width == 185)
    }

    @Test func hidingTheLiveActivityKeepsTheNotchToTheCamera() {
        let model = makeModel()
        model.trackTitle = TrackTitle()

        model.settings.isLiveActivityHidden = true

        #expect(!model.isShowingTrackTitle)
        #expect(!model.showsNowPlayingActivity)
        #expect(model.bodySize == CGSize(width: 185, height: 32))

        // Volume still shows.
        model.hud = HUDEvent(kind: .volume, level: 0.5)
        #expect(model.bodySize.width == 185 + 2 * NotchViewModel.Layout.hudSideWidth)
    }

    @Test func titleThatRanPastGoesUnlessAnotherTookItsPlace() {
        let model = makeModel()
        let first = TrackTitle()
        let second = TrackTitle()

        model.trackTitle = second
        model.finishTrackTitle(first.id)
        #expect(model.trackTitle == second)

        model.finishTrackTitle(second.id)
        #expect(model.trackTitle == nil)
    }

    @Test func otherEventsAndTheOpenNotchHideTheTrackTitle() {
        let model = makeModel()
        model.trackTitle = TrackTitle()

        model.hud = HUDEvent(kind: .volume, level: 0.5)
        #expect(!model.isShowingTrackTitle)
        #expect(model.bodySize.height == 32)
        #expect(model.lowerLidDepth == 0)
        #expect(model.bottomRadius == NotchViewModel.Layout.closedBottomRadius)

        model.hud = nil
        model.state = .open
        #expect(!model.isShowingTrackTitle)
    }

    @Test func pointerOnTheNotchOpensIt() {
        let model = makeModel()

        #expect(model.hoverRect.contains(CGPoint(x: 756, y: 981)))
        #expect(model.hoverRect.contains(CGPoint(x: 756 - 92, y: 960)))
    }

    @Test func pointerBesideOrBelowTheNotchDoesNot() {
        let model = makeModel()

        #expect(!model.hoverRect.contains(CGPoint(x: 600, y: 981)))
        #expect(!model.hoverRect.contains(CGPoint(x: 756, y: 900)))
    }

    @Test func openNotchStaysOpenAcrossItsWholeArea() {
        // The open area is larger than the closed one, so the notch doesn't flicker at its edge.
        let model = makeModel()
        let belowTheHardwareNotch = CGPoint(x: 756, y: 982 - 100)
        #expect(!model.hoverRect.contains(belowTheHardwareNotch))

        model.state = .open

        #expect(model.hoverRect.contains(belowTheHardwareNotch))
        #expect(model.hoverRect.contains(CGPoint(x: 756 - 225, y: 982 - 145)))
        // Below the dock, past the margin.
        #expect(!model.hoverRect.contains(CGPoint(x: 756, y: 982 - 300)))
    }

    @Test func draggedFilesOpenTheNotchFromFartherAway() {
        let model = makeModel()
        let belowTheNotch = CGPoint(x: 756, y: 982 - 32 - 16)
        #expect(!model.hoverRect.contains(belowTheNotch))

        model.isDraggingFiles = true
        #expect(model.hoverRect.contains(belowTheNotch))

        model.settings.shelfEnabled = false
        #expect(!model.hoverRect.contains(belowTheNotch))
    }

    @Test func theShelfSectionNeedsTheShelf() {
        let model = makeModel()
        #expect(model.selectedSection == .nowPlaying)

        model.selectedSection = .shelf
        #expect(model.currentSection == .shelf)

        model.settings.shelfEnabled = false
        #expect(model.currentSection == .nowPlaying)
    }

    @Test func filesDraggedOutTogetherAllLeaveTheShelf() throws {
        let files = try (1...3).map { index in
            let file = FileManager.default.temporaryDirectory.appending(path: "EyelidDragAll-\(index)-\(UUID().uuidString).txt")
            try Data("file \(index)".utf8).write(to: file)
            return file
        }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = makeModel()
        model.shelf.add(files)

        model.shelfDragSource.onDrop?(model.shelf.items.map(\.id))

        #expect(model.shelf.items.isEmpty)
    }

    @Test func filesDraggedOutLeaveTheShelf() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EyelidDragOut-\(UUID().uuidString).txt")
        try Data("taken".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = makeModel()
        model.shelf.add([file])
        let item = try #require(model.shelf.items.first)

        model.settings.shelfRemovesDraggedFiles = false
        model.shelfDragSource.onDrop?([item.id])
        #expect(model.shelf.items.count == 1)

        model.settings.shelfRemovesDraggedFiles = true
        model.shelfDragSource.onDrop?([item.id])
        #expect(model.shelf.items.isEmpty)
    }

    @Test func clipboardHistoryShowsOnceItsOn() {
        let model = makeModel()
        model.state = .open
        model.selectedSection = .clipboard
        #expect(model.currentSection == .nowPlaying)

        model.settings.clipboardEnabled = true

        #expect(model.currentSection == .clipboard)
    }

    @Test func clipboardSelectionStaysInTheList() throws {
        let model = makeModel()
        for text in ["one", "two", "three"] {
            model.clipboard.add(try #require(ClipboardEntry(items: [[.string: Data(text.utf8)]])))
        }

        model.moveClipboardSelection(by: -1)
        #expect(model.clipboardSelection == 0)
        model.moveClipboardSelection(by: 5)
        #expect(model.clipboardSelection == 2)

        model.removeSelectedClipboardEntry()
        #expect(model.clipboard.entries.count == 2)
        #expect(model.clipboardSelection == 1)
    }

    @Test func choosingAnEntryClosesTheNotch() throws {
        let model = makeModel()
        var closed = false
        model.close = { closed = true }
        model.clipboard.add(try #require(ClipboardEntry(items: [[.string: Data("hello".utf8)]])))

        model.chooseSelectedClipboardEntry()

        #expect(closed)
        #expect(model.clipboard.entries.count == 1)
    }

    @Test func returnClosesAnEmptyHistory() {
        let model = makeModel()
        var closed = false
        model.close = { closed = true }

        model.chooseSelectedClipboardEntry()

        #expect(closed)
    }

    @Test func aNewOutputComesBeforeABatteryEvent() {
        let model = makeModel()
        model.batteryEvent = .unplugged(BatteryState(level: 50, isPluggedIn: false, isCharging: false))

        model.output = OutputEvent(deviceID: "airpods", name: "AirPods Pro", icon: .airpodsPro)

        #expect(model.showsActivity)
        #expect(model.bodySize.width == 185 + 2 * NotchViewModel.Layout.hudSideWidth)
    }

    @Test func searchFiltersTheClipboardAndStartsAtTheTop() throws {
        let model = makeModel()
        for text in ["apple pie", "banana bread", "apple juice"] {
            model.clipboard.add(try #require(ClipboardEntry(items: [[.string: Data(text.utf8)]])))
        }
        model.clipboardSelection = 2

        model.clipboardQuery = "apple"

        #expect(model.visibleClipboardEntries.map(\.title) == ["apple juice", "apple pie"])
        #expect(model.clipboardSelection == 0)
        model.moveClipboardSelection(by: 5)
        #expect(model.selectedClipboardEntry?.title == "apple pie")
    }

    @Test func pinningKeepsTheSameCopySelected() throws {
        let model = makeModel()
        for text in ["one", "two", "three"] {
            model.clipboard.add(try #require(ClipboardEntry(items: [[.string: Data(text.utf8)]])))
        }
        model.clipboardSelection = 2

        model.togglePinOfSelectedClipboardEntry()

        #expect(model.selectedClipboardEntry?.title == "one")
        #expect(model.selectedClipboardEntry?.isPinned == true)
        #expect(model.clipboardSelection == 0)
    }

    @Test func choosingPastesOnlyWhenTurnedOn() throws {
        let model = makeModel()
        var pastes = 0
        model.pasteIntoFrontApp = { pastes += 1 }
        let entry = try #require(ClipboardEntry(items: [[.string: Data("hello".utf8)]]))

        model.choose(entry)
        #expect(pastes == 0)

        model.settings.clipboardPastesAfterChoosing = true
        model.choose(entry)
        #expect(pastes == 1)
    }

    // MARK: - Sections

    @Test func dockHoldsThePinnedSectionsInOrder() {
        let model = makeModel()
        model.settings.clipboardEnabled = true

        #expect(model.sections == [.nowPlaying, .shelf, .clipboard, .sound, .translation])
        #expect(model.dockSections == model.sections)

        model.settings.setPinned(.shelf, false)
        model.settings.moveSection(.translation, to: .nowPlaying)

        #expect(model.sections == [.translation, .nowPlaying, .shelf, .clipboard, .sound])
        #expect(model.dockSections == [.translation, .nowPlaying, .clipboard, .sound])
    }

    @Test func sectionsThatAreOffAreLeftOut() {
        let model = makeModel()
        model.settings.shelfEnabled = false
        model.selectedSection = .shelf

        #expect(model.sections == [.nowPlaying, .sound, .translation])
        #expect(model.currentSection == .nowPlaying)
    }

    @Test func menuOfAllSectionsTakesThePlaceOfTheCurrentOne() {
        let model = makeModel()
        model.state = .open
        model.settings.clipboardEnabled = true
        model.selectedSection = .clipboard
        model.showsSectionMenu = true

        model.select(.sound)

        #expect(!model.showsSectionMenu)
        #expect(model.selectedSection == .sound)
    }

    @Test func typingNeedsTheKeyboardOnTheTranslator() {
        let model = makeModel()
        model.state = .open
        model.selectedSection = .translation
        #expect(!model.isTypingTranslation)

        model.isHeldOpen = true
        #expect(model.isTypingTranslation)

        model.selectedSection = .clipboard
        #expect(!model.isTypingTranslation)
    }

    /// Only the clipboard history and the translator take typing; the other sections let go of the keyboard.
    @Test(arguments: [(NotchSection.shelf, true), (.sound, true), (.nowPlaying, true), (.translation, false), (.clipboard, false)])
    func sectionsWithoutTypingLetGoOfTheHold(section: NotchSection, releases: Bool) {
        let model = makeModel()
        model.state = .open
        model.selectedSection = .translation
        model.isHeldOpen = true
        var released = false
        model.releaseHold = { released = true }

        model.select(section)

        #expect(released == releases)
    }

    @Test func withoutTheTranslatorTheresNoTranslationSection() {
        let model = makeModel(translation: nil)
        model.selectedSection = .translation

        #expect(!model.sections.contains(.translation))
        #expect(model.currentSection == .nowPlaying)
    }

    @Test func theClipboardOpensAfresh() {
        let model = makeModel()
        model.settings.clipboardEnabled = true
        model.clipboardQuery = "addr"
        model.showsClipboardPreview = true

        model.select(.clipboard)

        #expect(model.clipboardQuery.isEmpty)
        #expect(!model.showsClipboardPreview)
    }

    @Test func aShelfWithFilesLooksFull() throws {
        let model = makeModel()
        #expect(model.systemImage(for: .shelf) == "tray")

        let file = FileManager.default.temporaryDirectory.appending(path: "EyelidShelfIcon-\(UUID().uuidString).txt")
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.shelf.add([file])

        #expect(model.systemImage(for: .shelf) == "tray.full")
    }

    /// Long enough to read, however short, and not forever, however long.
    @Test(arguments: zip([0, 60, 1_000], [6, 8, 30] as [Int64]))
    func translationStaysLongEnoughToRead(characters: Int, seconds: Int64) {
        let text = String(repeating: "a", count: characters)

        #expect(NotchViewModel.Layout.translationReadingTime(for: text) == .seconds(seconds))
    }
}
