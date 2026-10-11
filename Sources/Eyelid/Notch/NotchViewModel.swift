import AppKit
import Observation

@MainActor
@Observable
final class NotchViewModel {
    enum State {
        case closed
        case open
    }

    /// What the open notch shows below the strip beside the hardware notch.
    typealias Tab = NotchSection

    enum Layout {
        static let openWidth: CGFloat = 470
        /// Room between the open notch's content and its sides.
        static let openHorizontalPadding: CGFloat = 18
        /// Room below the open notch's content.
        static let openBottomPadding: CGFloat = 14
        /// The dock of pinned sections along the bottom of the open notch.
        static let dockHeight: CGFloat = 34
        /// Tiles in the menu of all sections: this many a row, this tall, this far apart.
        static let sectionMenuColumns = 4
        static let sectionTileHeight: CGFloat = 44
        static let sectionTileSpacing: CGFloat = 6
        /// Height of the open notch's section, between the strip beside the camera and the dock. The same for every
        /// section, so switching between them in the dock doesn't pull the notch out from under the pointer.
        static let openContentHeight: CGFloat = 200
        /// The Sound section's volume row and Sound Settings link, and the height of each output.
        static let soundFixedHeight: CGFloat = 70
        static let soundRowHeight: CGFloat = 26
        /// As many outputs as fit the section.
        static let soundMaxRows = Int((openContentHeight - soundFixedHeight) / soundRowHeight)
        /// Extra room on each side of the closed notch for the live activity.
        static let activitySideWidth: CGFloat = 42
        /// Room on each side of the closed notch for the volume and brightness HUD.
        static let hudSideWidth: CGFloat = 70
        /// How long the HUD stays after the last key press, in seconds.
        static let hudDuration: TimeInterval = 1.5
        /// How long a battery event stays next to the closed notch, in seconds.
        static let batteryEventDuration: TimeInterval = 3
        /// How long a new sound output stays next to the closed notch, in seconds.
        static let outputEventDuration: TimeInterval = 3
        /// How long a translation nobody looks at stays open: time to read both texts, at about 15 characters a second
        /// for the original, within limits.
        static func translationReadingTime(for text: String) -> Duration {
            .seconds(min(max(4 + Double(text.count) / 15, 6), 30))
        }
        /// How far the lower lid hangs below the hardware notch, in the middle, to show the track title.
        static let trackTitleHeight: CGFloat = 30
        /// How far above the bottom of the lid the title runs.
        static let trackTitleInset: CGFloat = 8
        /// The corners of the lid are pointed, like the corners of an eye.
        static let lidBottomRadius: CGFloat = 2
        /// Transparent margin around the open notch so its shadow is not clipped.
        static let shadowPadding: CGFloat = 40
        /// How far around the closed notch dragged files open it, which makes the notch easier to hit.
        static let fileDragMargin: CGFloat = 24

        static let closedTopRadius: CGFloat = 6
        static let closedBottomRadius: CGFloat = 10
        static let openTopRadius: CGFloat = 14
        static let openBottomRadius: CGFloat = 26
    }

    var state: State = .closed
    var tab: Tab = .nowPlaying
    var geometry: NotchGeometry
    /// The volume or brightness after a key press. Shown in place of everything else.
    var hud: HUDEvent?
    /// Shown next to the closed notch for a few seconds, in place of now playing.
    var batteryEvent: BatteryEvent?
    /// Where sound just switched to, or the earbuds in use as they change. Shown in place of a battery event or now
    /// playing.
    var output: OutputEvent?
    /// What just started playing, shown under the closed notch for a moment.
    var trackTitle: TrackTitle?
    /// Whether files are being dragged anywhere on the screen, which may end on the notch.
    var isDraggingFiles = false
    /// Whether files are being dragged over the open notch, which would add them to the shelf.
    var isDropTargeted = false
    /// Whether the open notch shows the menu of all sections, in place of the current one.
    var showsSectionMenu = false
    /// Whether the notch has the keyboard and stays open wherever the pointer goes: for the clipboard history after
    /// its shortcut, or for typing a translation, until Escape, a click elsewhere, or an entry is picked.
    var isHeldOpen = false
    /// Whether the notch stays open after showing a translation, until the pointer has been over it and left, a
    /// click elsewhere, or it has had time to be read.
    var isTranslationHeld = false
    /// The clipboard entry that Return copies, by its place in the list.
    var clipboardSelection = 0
    /// What's been typed to search the clipboard history.
    var clipboardQuery = "" {
        didSet { clipboardSelection = 0 }
    }
    /// Whether the selected copy shows in full, in place of the list.
    var showsClipboardPreview = false
    let nowPlaying: NowPlayingService
    /// The sound itself, for the equalizer, while Eyelid listens to it.
    let audioLevels: AudioLevels
    let battery: BatteryService
    let shelf: Shelf
    let clipboard: ClipboardHistory
    let translator: Translator
    let settings: AppSettings
    @ObservationIgnored let shelfDragSource = ShelfDragSource()
    /// The volume and outputs, for the Sound tab.
    let sound = SoundControl()
    /// Whether the pointer is over the equalizer beside the closed notch, which it then highlights.
    var isHoveringEqualizer = false
    /// Opens the notch on the Sound tab. Set by the window controller, which owns opening.
    @ObservationIgnored var openSound: @MainActor () -> Void = {}
    /// Gives the translation's text field the keyboard, after a click on it. Set by the window controller.
    @ObservationIgnored var typeTranslation: @MainActor () -> Void = {}
    /// Set by the window controller, which owns opening and closing.
    @ObservationIgnored var close: @MainActor () -> Void = {}
    /// Presses ⌘V in the app in front. Set by the window controller, which knows when it has the keyboard back.
    @ObservationIgnored var pasteIntoFrontApp: @MainActor () -> Void = {}

    init(
        geometry: NotchGeometry,
        nowPlaying: NowPlayingService,
        audioLevels: AudioLevels,
        battery: BatteryService,
        shelf: Shelf,
        clipboard: ClipboardHistory,
        translator: Translator,
        settings: AppSettings
    ) {
        self.geometry = geometry
        self.nowPlaying = nowPlaying
        self.audioLevels = audioLevels
        self.battery = battery
        self.shelf = shelf
        self.clipboard = clipboard
        self.translator = translator
        self.settings = settings
        shelfDragSource.onDrop = { [weak self] items in
            self?.didDragOut(items)
        }
    }

    /// Whether the open notch shows the shelf rather than now playing.
    var showsShelf: Bool {
        settings.shelfEnabled && tab == .shelf
    }

    var showsClipboard: Bool {
        settings.clipboardEnabled && tab == .clipboard
    }

    var showsSound: Bool {
        tab == .sound
    }

    var showsTranslation: Bool {
        tab == .translation && translator.isAvailable
    }

    /// The sections there are, in the user's order: the shelf and the clipboard history only while they're on, and
    /// the translator on Macs that can translate.
    var sections: [NotchSection] {
        settings.sectionOrder.filter { section in
            switch section {
            case .shelf: settings.shelfEnabled
            case .clipboard: settings.clipboardEnabled
            case .translation: translator.isAvailable
            case .nowPlaying, .sound: true
            }
        }
    }

    /// The pinned sections, in the dock at the bottom of the open notch.
    var dockSections: [NotchSection] {
        Array(sections.filter(settings.pinnedSections.contains).prefix(NotchSection.maxPinned))
    }

    /// The section the open notch shows: the chosen one, or Now Playing when that one is off.
    var currentSection: NotchSection {
        sections.contains(tab) ? tab : .nowPlaying
    }

    /// Shows a section, and puts the menu of all sections away.
    func select(_ section: NotchSection) {
        if section == .clipboard {
            resetClipboard()
        }
        tab = section
        showsSectionMenu = false
    }

    /// The section's icon, with a full tray for a shelf with files on it.
    func systemImage(for section: NotchSection) -> String {
        section == .shelf && !shelf.items.isEmpty ? "tray.full" : section.systemImage
    }

    /// Whether the translation's text field has the keyboard, which holds the notch open.
    var isTypingTranslation: Bool {
        state == .open && isHeldOpen && tab == .translation
    }

    /// The clipboard entries that match what's been typed.
    var visibleClipboardEntries: [ClipboardEntry] {
        clipboard.entries.filter { $0.matches(clipboardQuery) }
    }

    var selectedClipboardEntry: ClipboardEntry? {
        let entries = visibleClipboardEntries
        return entries.indices.contains(clipboardSelection) ? entries[clipboardSelection] : nil
    }

    /// Starts the clipboard history afresh: first entry selected, no search, no preview.
    func resetClipboard() {
        clipboardQuery = ""
        clipboardSelection = 0
        showsClipboardPreview = false
    }

    /// Puts a clipboard entry back on the pasteboard and closes the notch, then pastes it if that's turned on.
    func choose(_ entry: ClipboardEntry) {
        clipboard.copy(entry)
        close()
        if settings.clipboardPastesAfterChoosing {
            pasteIntoFrontApp()
        }
    }

    /// Moves the clipboard selection up or down the list, staying within it.
    func moveClipboardSelection(by offset: Int) {
        let last = visibleClipboardEntries.count - 1
        clipboardSelection = max(0, min(last, clipboardSelection + offset))
    }

    /// With nothing to choose, Return just closes the history, so the keys typed next reach the app in front.
    func chooseSelectedClipboardEntry() {
        guard let entry = selectedClipboardEntry else {
            close()
            return
        }
        choose(entry)
    }

    func removeSelectedClipboardEntry() {
        guard let entry = selectedClipboardEntry else { return }
        clipboard.remove(entry.id)
        moveClipboardSelection(by: 0)
    }

    func togglePinOfSelectedClipboardEntry() {
        guard let entry = selectedClipboardEntry else { return }
        clipboard.setPinned(entry.id, !entry.isPinned)
        // Keep the same copy selected after it moved.
        clipboardSelection = visibleClipboardEntries.firstIndex { $0.id == entry.id } ?? 0
    }

    private func didDragOut(_ items: [ShelfItem.ID]) {
        guard settings.shelfRemovesDraggedFiles else { return }
        for item in items {
            shelf.remove(item)
        }
    }

    /// Whether the closed notch grows sideways to show the HUD, a battery event, or artwork and an equalizer.
    var showsActivity: Bool {
        hud != nil || output != nil || batteryEvent != nil || showsNowPlayingActivity || showsIdleActivity
    }

    /// The time and the battery beside the closed notch while nothing plays, if that's turned on.
    var showsIdleActivity: Bool {
        settings.showsClockWhenIdle && !settings.isLiveActivityHidden && !showsNowPlayingActivity
            && hud == nil && output == nil && batteryEvent == nil
    }

    var showsNowPlayingActivity: Bool {
        // Not for a muted preview, which reports playing but sends no sound.
        settings.showsLiveActivity && !settings.isLiveActivityHidden
            && nowPlaying.track?.isPlaying == true && !nowPlaying.isSilent
    }

    /// Whether the closed notch drops down to show the track title. The HUD, battery and output events go first.
    var isShowingTrackTitle: Bool {
        state == .closed && trackTitle != nil && !settings.isLiveActivityHidden
            && hud == nil && output == nil && batteryEvent == nil
    }

    /// The lower lid hangs from the bottom corners while the notch shows the track title.
    var lowerLidDepth: CGFloat {
        isShowingTrackTitle ? Layout.trackTitleHeight : 0
    }

    /// Takes the title away once it has run past, unless another one took its place.
    func finishTrackTitle(_ id: TrackTitle.ID) {
        if trackTitle?.id == id {
            trackTitle = nil
        }
    }

    /// The equalizer right of the closed notch, in global coordinates, while it shows. Hovering it doesn't open the
    /// notch, and clicking it opens the Sound tab.
    var equalizerRect: CGRect? {
        guard state == .closed, showsNowPlayingActivity, hud == nil, output == nil, batteryEvent == nil else { return nil }
        let notch = geometry.notchSize
        return CGRect(
            x: geometry.notchMidX + notch.width / 2,
            y: geometry.screenFrame.maxY - notch.height,
            width: Layout.activitySideWidth,
            height: notch.height
        )
    }

    /// Room right of the camera in the open notch, for the date, time and battery.
    var statusWidth: CGFloat {
        (Layout.openWidth - geometry.notchSize.width) / 2 - Layout.openHorizontalPadding
    }

    /// Size of the notch body, excluding the ears.
    var bodySize: CGSize {
        let notch = geometry.notchSize
        switch state {
        case .open:
            return CGSize(width: Layout.openWidth, height: notch.height + Layout.openContentHeight + Layout.dockHeight)
        case .closed:
            let sideWidth = hud != nil || output != nil
                ? Layout.hudSideWidth
                : (showsActivity || isShowingTrackTitle ? Layout.activitySideWidth : 0)
            let extra = 2 * sideWidth
            let height = notch.height + (isShowingTrackTitle ? Layout.trackTitleHeight : 0)
            return CGSize(width: notch.width + extra, height: height)
        }
    }

    var topRadius: CGFloat {
        state == .open ? Layout.openTopRadius : Layout.closedTopRadius
    }

    var bottomRadius: CGFloat {
        if state == .open {
            return Layout.openBottomRadius
        }
        return isShowingTrackTitle ? Layout.lidBottomRadius : Layout.closedBottomRadius
    }

    /// The panel is sized once for the tallest open state and never resized, which keeps animations smooth.
    var windowSize: CGSize {
        CGSize(
            width: Layout.openWidth + 2 * Layout.openTopRadius + 2 * Layout.shadowPadding,
            height: geometry.notchSize.height
                + Layout.openContentHeight
                + Layout.dockHeight
                + Layout.shadowPadding
        )
    }

    /// The notch body in global coordinates.
    var bodyRect: CGRect {
        let size = bodySize
        return CGRect(
            x: geometry.notchMidX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Area in global coordinates where the cursor opens the notch, or keeps it open.
    /// The open area is more forgiving, so the notch does not flicker at its edge.
    var hoverRect: CGRect {
        let margin: CGFloat
        switch state {
        case .open:
            margin = 12
        case .closed:
            margin = isDraggingFiles && settings.shelfEnabled ? Layout.fileDragMargin : 4
        }
        return bodyRect.insetBy(dx: -margin, dy: -margin)
    }
}
