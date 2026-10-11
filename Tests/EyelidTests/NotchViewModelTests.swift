import Foundation
import Testing
@testable import Eyelid

@MainActor
@Suite("Notch layout")
struct NotchViewModelTests {
    /// A 14-inch MacBook Pro: 1512×982 points with a 185×32 notch in the middle.
    private let geometry = NotchGeometry(
        notchSize: CGSize(width: 185, height: 32),
        notchMidX: 756,
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
    )

    private func makeModel() -> NotchViewModel {
        let settings = AppSettings(defaults: InMemorySettingsStore())
        let nowPlaying = NowPlayingService()
        return NotchViewModel(
            geometry: geometry,
            nowPlaying: nowPlaying,
            audioLevels: AudioLevels(settings: settings, nowPlaying: nowPlaying),
            battery: BatteryService(),
            shelf: Shelf(store: InMemorySettingsStore(), promisedFilesDirectory: FileManager.default.temporaryDirectory),
            clipboard: ClipboardHistory(pasteboard: .withUniqueName(), pinnedFile: nil),
            translator: Translator(settings: settings, engine: .fake(), pasteboard: .withUniqueName()),
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

    @Test func equalizerIsClickableOnlyWhileItShows() {
        let model = makeModel()
        #expect(model.equalizerRect == nil)

        model.settings.isLiveActivityHidden = false
        model.state = .open
        #expect(model.equalizerRect == nil)
    }

    @Test func statusFitsRightOfTheCamera() {
        let model = makeModel()

        #expect(model.statusWidth == (NotchViewModel.Layout.openWidth - 185) / 2 - NotchViewModel.Layout.openHorizontalPadding)
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

    @Test func shelfTabNeedsTheShelf() {
        let model = makeModel()
        #expect(model.tab == .nowPlaying)

        model.tab = .shelf
        #expect(model.showsShelf)

        model.settings.shelfEnabled = false
        #expect(!model.showsShelf)
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
        model.tab = .clipboard
        #expect(!model.showsClipboard)

        model.settings.clipboardEnabled = true

        #expect(model.showsClipboard)
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
        model.tab = .shelf

        #expect(model.sections == [.nowPlaying, .sound, .translation])
        #expect(model.currentSection == .nowPlaying)
    }

    @Test func menuOfAllSectionsTakesThePlaceOfTheCurrentOne() {
        let model = makeModel()
        model.state = .open
        model.settings.clipboardEnabled = true
        model.tab = .clipboard
        model.showsSectionMenu = true

        model.select(.sound)

        #expect(!model.showsSectionMenu)
        #expect(model.tab == .sound)
    }

    @Test func typingNeedsTheKeyboardOnTheTranslator() {
        let model = makeModel()
        model.state = .open
        model.tab = .translation
        #expect(!model.isTypingTranslation)

        model.isHeldOpen = true
        #expect(model.isTypingTranslation)

        model.tab = .clipboard
        #expect(!model.isTypingTranslation)
    }
}
