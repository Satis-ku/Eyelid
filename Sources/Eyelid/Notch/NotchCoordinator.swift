import AppKit
import Observation

/// Keeps a notch on each display that should show one, as displays come and go and the setting changes, and sends
/// each event to the notch the user is looking at.
@MainActor
final class NotchCoordinator {
    private let nowPlaying: NowPlayingService
    private let audioLevels: AudioLevels
    private let battery: BatteryService
    private let shelf: Shelf
    private let clipboard: ClipboardHistory
    private let translator: Translator
    private let appVolumes: AppVolumes
    private let settings: AppSettings
    private var controllers: [NotchWindowController] = []
    private var pointerMonitors: [Any] = []
    /// The display the pointer was on at the last look, for the automatic choice to follow it.
    private var pointerDisplay: CGDirectDisplayID?

    init(
        nowPlaying: NowPlayingService,
        audioLevels: AudioLevels,
        battery: BatteryService,
        output: OutputService,
        shelf: Shelf,
        clipboard: ClipboardHistory,
        clipboardShortcut: Shortcut,
        lidShortcut: Shortcut,
        translator: Translator,
        appVolumes: AppVolumes,
        doubleCopy: DoubleCopyWatcher,
        translationShortcut: Shortcut,
        hud: HUDService,
        settings: AppSettings
    ) {
        self.nowPlaying = nowPlaying
        self.audioLevels = audioLevels
        self.battery = battery
        self.shelf = shelf
        self.clipboard = clipboard
        self.translator = translator
        self.appVolumes = appVolumes
        self.settings = settings

        pointerDisplay = NSScreen.withPointer?.displayID
        updateNotches()
        followDisplaySetting()
        followPointer()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateNotches()
            }
        }

        battery.onEvent = { [weak self] event in
            self?.activeNotch?.show(event)
        }
        output.onEvent = { [weak self] event in
            self?.activeNotch?.show(event)
        }
        hud.onEvent = { [weak self] event in
            self?.activeNotch?.show(event)
        }
        nowPlaying.onPlaybackStart = { [weak self] in
            guard let self, settings.showsTrackTitle else { return }
            activeNotch?.showTrackTitle()
        }
        lidShortcut.onPress = { [weak self] in
            self?.toggleLiveActivity()
        }
        clipboardShortcut.onPress = { [weak self] in
            self?.toggleClipboard()
        }
        doubleCopy.onDoubleCopy = { [weak self] in
            self?.translateCopiedText()
        }
        translationShortcut.onPress = { [weak self] in
            self?.toggleTranslator()
        }
    }

    /// The notch on the display with the pointer, which is where the user is looking.
    private var activeNotch: NotchWindowController? {
        let pointer = NSEvent.mouseLocation
        return controllers.first { $0.screenFrame.contains(pointer) } ?? controllers.first
    }

    /// Hides the live activity and track titles, or shows them again. They stay hidden across launches.
    private func toggleLiveActivity() {
        settings.isLiveActivityHidden.toggle()
    }

    /// Opens the clipboard history where the user is looking, or closes it wherever it's open.
    private func toggleClipboard() {
        if let open = controllers.first(where: \.isHoldingClipboardOpen) {
            open.toggleClipboard()
        } else {
            activeNotch?.toggleClipboard()
        }
    }

    /// Opens the translator to type in where the user is looking, or closes it wherever it's open.
    private func toggleTranslator() {
        guard translator.isAvailable else { return }
        if let open = controllers.first(where: \.isTypingTranslation) {
            open.toggleTranslator()
        } else {
            activeNotch?.toggleTranslator()
        }
    }

    /// Translates what was copied, and shows it where the user is looking.
    private func translateCopiedText() {
        translator.translateCopiedText()
        activeNotch?.showTranslation()
    }

    // MARK: - Displays

    private func followDisplaySetting() {
        withObservationTracking {
            _ = settings.notchDisplays
        } onChange: { [weak self] in
            // `onChange` runs before the new value is stored, so read it on the next turn of the main actor.
            Task { @MainActor in
                self?.updateNotches()
                self?.followDisplaySetting()
            }
        }
    }

    /// The automatic choice follows the pointer: when it crosses to another display, so does the notch. Not while the
    /// notch is open, so it doesn't jump away from what the user is doing in it.
    private func followPointer() {
        let handler: @MainActor () -> Void = { [weak self] in
            guard let self, let display = NSScreen.withPointer?.displayID, display != pointerDisplay else { return }
            pointerDisplay = display
            guard settings.notchDisplays == .automatic, !controllers.contains(where: \.isOpen) else { return }
            updateNotches()
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated(handler)
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated(handler)
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// Keeps the notches of displays that still show one, moves the others to the displays that now need one, adds any
    /// still missing, and takes down the rest.
    private func updateNotches() {
        let screens = settings.notchDisplays.screens
        var kept: [NotchWindowController] = []
        var spare = controllers.filter { controller in
            !screens.contains { $0.displayID == controller.displayID }
        }

        for screen in screens {
            if let controller = controllers.first(where: { $0.displayID == screen.displayID }) {
                controller.move(to: screen)
                kept.append(controller)
            } else if !spare.isEmpty {
                let controller = spare.removeFirst()
                controller.move(to: screen)
                kept.append(controller)
            } else {
                kept.append(NotchWindowController(
                    screen: screen,
                    nowPlaying: nowPlaying,
                    audioLevels: audioLevels,
                    battery: battery,
                    shelf: shelf,
                    clipboard: clipboard,
                    translator: translator,
                    appVolumes: appVolumes,
                    settings: settings
                ))
            }
        }

        for controller in spare {
            controller.invalidate()
        }
        controllers = kept
    }
}
