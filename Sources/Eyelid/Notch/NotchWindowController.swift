import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Notch")

/// Owns the notch panel of one display: keeps it pinned to the notch and opens or closes it as the cursor moves.
@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let model: NotchViewModel
    private let settings: AppSettings
    private var mouseMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var openTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var batteryEventTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var trackTitleTask: Task<Void, Never>?
    /// Closes a translation nobody looked at, once it has had time to be read.
    private var translationTask: Task<Void, Never>?
    /// The drag pasteboard changes when a drag starts, which tells drags apart from other mouse moves.
    private var dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    /// Handles the arrow keys, Return, Delete and Escape while the clipboard history has the keyboard.
    private var keyMonitor: Any?

    init(
        screen: NSScreen,
        nowPlaying: NowPlayingService,
        audioLevels: AudioLevels,
        battery: BatteryService,
        shelf: Shelf,
        clipboard: ClipboardHistory,
        translator: Translator,
        settings: AppSettings
    ) {
        self.settings = settings
        model = NotchViewModel(
            geometry: NotchGeometry(screen: screen),
            nowPlaying: nowPlaying,
            audioLevels: audioLevels,
            battery: battery,
            shelf: shelf,
            clipboard: clipboard,
            translator: translator,
            settings: settings
        )

        let hostingView = NotchHostingView(rootView: NotchView(model: model))
        hostingView.sizingOptions = []
        let dropView = NotchDropView(content: hostingView)
        panel.contentView = dropView
        dropView.delegate = self

        updateFrame()
        panel.orderFrontRegardless()

        installMouseMonitors()
        model.close = { [weak self] in
            self?.close()
        }
        model.pasteIntoFrontApp = {
            Paster.paste()
        }
        model.openSound = { [weak self] in
            self?.openSound()
        }
        model.typeTranslation = { [weak self] in
            self?.beginTypingTranslation()
        }
        // Clicking another window takes the keyboard away from the clipboard history, which then goes away.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model.isHeldOpen == true {
                    self?.close()
                }
            }
        })
    }

    /// Takes the panel down for good, when its display goes away or no longer shows a notch.
    func invalidate() {
        if model.isHeldOpen {
            close()
        }
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors = []
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        for task in [openTask, pollTask, batteryEventTask, hudTask, outputTask, trackTitleTask, translationTask] {
            task?.cancel()
        }
        panel.orderOut(nil)
    }

    // MARK: - Placement

    /// The display this notch is on.
    var displayID: CGDirectDisplayID? {
        model.geometry.displayID
    }

    /// The whole display this notch is on, in global coordinates.
    var screenFrame: CGRect {
        model.geometry.screenFrame
    }

    /// Follows the display when its size or arrangement changes.
    func move(to screen: NSScreen) {
        let geometry = NotchGeometry(screen: screen)
        guard geometry != model.geometry else { return }
        model.geometry = geometry
        updateFrame()
    }

    private func updateFrame() {
        let geometry = model.geometry
        let size = model.windowSize
        let frame = CGRect(
            x: geometry.notchMidX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - Volume and brightness

    func show(_ event: HUDEvent) {
        // The Sound tab shows the volume already, and moves with the slider.
        if event.kind == .volume, model.state == .open, model.showsSound {
            return
        }
        dismissTrackTitle()
        model.hud = event
        // Holding a key repeats it, so the HUD stays until the last press plus the duration.
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchViewModel.Layout.hudDuration))
            guard !Task.isCancelled else { return }
            self?.model.hud = nil
        }
    }

    // MARK: - Battery

    func show(_ event: BatteryEvent) {
        logger.debug("Battery event: \(String(describing: event), privacy: .public)")
        guard settings.batteryActivityEnabled else { return }

        dismissTrackTitle()
        model.batteryEvent = event
        batteryEventTask?.cancel()
        batteryEventTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchViewModel.Layout.batteryEventDuration))
            guard !Task.isCancelled else { return }
            self?.model.batteryEvent = nil
        }
    }

    // MARK: - Sound output

    func show(_ event: OutputEvent) {
        dismissTrackTitle()
        model.output = event
        outputTask?.cancel()
        outputTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchViewModel.Layout.outputEventDuration))
            guard !Task.isCancelled else { return }
            self?.model.output = nil
        }
    }

    // MARK: - Track title

    /// Drops the lower lid to run what started playing along it. The open notch shows the track in full already.
    func showTrackTitle() {
        guard model.state == .closed, !settings.isLiveActivityHidden else { return }
        let title = TrackTitle()
        model.trackTitle = title
        // The title ends itself once it has run past. This is in case it never shows, behind the HUD for one.
        trackTitleTask?.cancel()
        trackTitleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TrackTitle.maxDuration + 2))
            guard !Task.isCancelled else { return }
            self?.model.finishTrackTitle(title.id)
        }
    }

    /// Something else needs the notch, so the title goes now rather than coming back after it.
    private func dismissTrackTitle() {
        trackTitleTask?.cancel()
        trackTitleTask = nil
        model.trackTitle = nil
    }

    // MARK: - Translation

    /// Opens the translator with the keyboard, wherever the pointer is, to type or paste text; or closes it.
    func toggleTranslator() {
        if model.isTypingTranslation {
            close()
            return
        }
        beginTypingTranslation()
    }

    /// Gives the translation's field the keyboard, and holds the notch open until Escape or a click elsewhere.
    private func beginTypingTranslation() {
        model.isTranslationHeld = false
        translationTask?.cancel()
        translationTask = nil
        if model.state == .open {
            model.tab = .translation
        } else {
            open(on: .translation)
        }
        model.isHeldOpen = true
        takeKeyboard()
    }

    /// Opens the notch on the translation of what was just copied, wherever the pointer is. It stays open until the
    /// pointer has been over it and left, or a click elsewhere, or for as long as it takes to read if neither comes.
    func showTranslation() {
        if model.isHeldOpen {
            close()
        }
        open(on: .translation)
        model.isTranslationHeld = true

        let readingTime = NotchViewModel.Layout.translationReadingTime(for: model.translator.request?.text ?? "")
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            try? await Task.sleep(for: readingTime)
            guard !Task.isCancelled, let self, model.isTranslationHeld else { return }
            close()
        }
    }

    // MARK: - Sound

    /// Opens the notch on the Sound tab, after a click on the equalizer.
    private func openSound() {
        open(on: .sound)
    }

    // MARK: - Hover

    private func installMouseMonitors() {
        // Mouse events, unlike key events, can be observed without the Accessibility permission.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.handleMouse(type)
            }
        }) {
            mouseMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                self?.handleMouse(type)
            }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func handleMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            // A click anywhere else puts away the clipboard history, as with a menu, and a translation.
            if model.isHeldOpen || model.isTranslationHeld, !model.bodyRect.contains(NSEvent.mouseLocation) {
                close()
            }
        case .leftMouseDragged:
            noticeFileDrag()
        case .leftMouseUp:
            model.isDraggingFiles = false
        default:
            break
        }
        updateHover()
    }

    /// Notices files being dragged, so the notch opens to the shelf for them, and opens from a little farther away.
    private func noticeFileDrag() {
        guard settings.shelfEnabled, !model.isDraggingFiles else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragPasteboardChangeCount else { return }
        dragPasteboardChangeCount = pasteboard.changeCount
        model.isDraggingFiles = ShelfDrop.carriesFiles(pasteboard.types)
    }

    private func updateHover() {
        // The mouse-up that ends a drag can go unseen, for example when it ends on the notch.
        if model.isDraggingFiles, NSEvent.pressedMouseButtons & 1 == 0 {
            model.isDraggingFiles = false
        }

        let pointer = NSEvent.mouseLocation
        // The equalizer takes clicks, for the Sound tab, rather than opening the notch on hover.
        let isOverEqualizer = model.equalizerRect?.contains(pointer) == true
        if model.state == .closed {
            panel.ignoresMouseEvents = !isOverEqualizer
        }
        if isOverEqualizer != model.isHoveringEqualizer {
            model.isHoveringEqualizer = isOverEqualizer
            if isOverEqualizer, settings.hapticsEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
        let isInside = model.hoverRect.contains(pointer) && !isOverEqualizer
        switch (model.state, isInside) {
        case (.closed, true):
            scheduleOpen()
        case (.closed, false):
            openTask?.cancel()
            openTask = nil
        case (.open, false):
            if !model.isHeldOpen, !model.isTranslationHeld {
                close()
            }
        case (.open, true):
            // Once the pointer has been over a translation, it closes as the notch always does.
            if model.isTranslationHeld {
                model.isTranslationHeld = false
            }
        }
    }

    private func scheduleOpen() {
        let delay = settings.openDelay
        guard delay > 0 else {
            open()
            return
        }
        guard openTask == nil else { return }

        // Leaving the notch before the delay is up cancels the task in `updateHover`.
        openTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    /// Opens on `tab` when there's a reason for it: the clipboard shortcut, or a click on the equalizer. Otherwise on
    /// the shelf for files being dragged, on Now Playing while something is heard, and on the last tab otherwise.
    private func open(on tab: NotchViewModel.Tab? = nil) {
        logger.debug("Opened")
        openTask?.cancel()
        openTask = nil
        dismissTrackTitle()
        if let tab {
            model.tab = tab
        } else if settings.shelfEnabled, model.isDraggingFiles {
            model.tab = .shelf
        } else if model.nowPlaying.track?.isPlaying == true, !model.nowPlaying.isSilent {
            model.tab = .nowPlaying
        }
        if settings.shelfEnabled {
            model.shelf.refresh()
        }
        model.state = .open
        panel.ignoresMouseEvents = false
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        // While the cursor is over the panel, global monitors go quiet, so poll to notice it leaving.
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.updateHover()
            }
        }
    }

    private func close() {
        logger.debug("Closed")
        let wasPinned = model.isHeldOpen
        model.state = .closed
        model.isDropTargeted = false
        model.isHeldOpen = false
        if wasPinned {
            giveUpKeyboard()
        }
        model.isTranslationHeld = false
        translationTask?.cancel()
        translationTask = nil
        panel.ignoresMouseEvents = true
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Clipboard

extension NotchWindowController {
    /// Whether the notch is open, for hover, a drag or the clipboard history.
    var isOpen: Bool {
        model.state == .open
    }

    /// Whether the clipboard history is open and holding the notch open.
    var isHoldingClipboardOpen: Bool {
        model.isHeldOpen && model.tab == .clipboard
    }

    /// Whether the translation's field has the keyboard.
    var isTypingTranslation: Bool {
        model.isTypingTranslation
    }

    /// The clipboard shortcut opens the history, wherever the pointer is, and closes it again.
    func toggleClipboard() {
        if isHoldingClipboardOpen {
            close()
            return
        }
        guard settings.clipboardEnabled else { return }

        logger.debug("Opened the clipboard history")
        model.resetClipboard()
        model.isHeldOpen = true
        open(on: .clipboard)
        takeKeyboard()
    }

    /// Makes the panel key, so the arrow keys, Return, Delete and Escape reach the history, and only while it's
    /// open: the app in front stays active, and no other app loses those keys.
    private func takeKeyboard() {
        guard keyMonitor == nil else { return }
        panel.allowsKey = true
        panel.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = ClipboardKey(event: event)
            let editing = TextEditingKey(event: event)
            let isHandled = MainActor.assumeIsolated {
                self?.handle(key, editing: editing) ?? false
            }
            return isHandled ? nil : event
        }
    }

    private func giveUpKeyboard() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        panel.allowsKey = false
        // A window can't be told to stop being key. Ordering the panel out and back in hands the keyboard back
        // to the app in front, as closing a menu does.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func handle(_ key: ClipboardKey, editing: TextEditingKey?) -> Bool {
        // The translation's field takes the keys itself, but for Escape, which closes the notch, and the editing
        // shortcuts, which it gets from here.
        guard model.tab == .clipboard else {
            if key == .escape {
                close()
                return true
            }
            if let editing {
                return NSApp.sendAction(editing.action, to: nil, from: nil)
            }
            return false
        }
        switch key {
        case .up:
            model.moveClipboardSelection(by: -1)
        case .down:
            model.moveClipboardSelection(by: 1)
        case .choose:
            model.chooseSelectedClipboardEntry()
        case .remove:
            model.removeSelectedClipboardEntry()
        case .togglePin:
            model.togglePinOfSelectedClipboardEntry()
        case .togglePreview:
            model.showsClipboardPreview.toggle()
        case .space:
            if model.clipboardQuery.isEmpty {
                model.showsClipboardPreview.toggle()
            } else {
                model.clipboardQuery += " "
            }
        case .deleteBackward:
            guard !model.clipboardQuery.isEmpty else { return false }
            model.clipboardQuery.removeLast()
        case .type(let text):
            model.clipboardQuery += text
        case .escape:
            // Escape steps back: out of the preview, then out of the search, then out of the history.
            if model.showsClipboardPreview {
                model.showsClipboardPreview = false
            } else if !model.clipboardQuery.isEmpty {
                model.clipboardQuery = ""
            } else {
                close()
            }
        case .other:
            return false
        }
        return true
    }
}

// MARK: - Shelf

extension NotchWindowController: NotchDropDelegate {
    func dropOperation(for drag: any NSDraggingInfo) -> NSDragOperation {
        let operation = acceptedOperation(for: drag)
        model.isDropTargeted = operation != []
        if operation != [] {
            model.tab = .shelf
        }
        return operation
    }

    func dragDidExit() {
        model.isDropTargeted = false
    }

    func performDrop(_ drag: any NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        model.isDraggingFiles = false
        guard acceptedOperation(for: drag) != [] else { return false }

        let received = ShelfDrop.receive(drag.draggingPasteboard, into: model.shelf)
        logger.debug("Dropped files on the shelf: \(received, privacy: .public)")
        if received, settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        return received
    }

    private func acceptedOperation(for drag: any NSDraggingInfo) -> NSDragOperation {
        let location = panel.convertPoint(toScreen: drag.draggingLocation)
        guard settings.shelfEnabled,
              model.state == .open,
              // Files dragged out of the shelf come from Eyelid itself, and have nowhere else to go in it.
              drag.draggingSource == nil,
              ShelfDrop.carriesFiles(drag.draggingPasteboard.types),
              // The panel is larger than the notch, to make room for its shadow.
              model.bodyRect.contains(location)
        else { return [] }

        // The shelf only keeps a reference, so the files stay where they are, but "copy" is what apps that promise
        // files expect, and what shows the plus on the pointer.
        let offered = drag.draggingSourceOperationMask
        return [.copy, .generic, .link].first { offered.contains($0) } ?? []
    }
}
