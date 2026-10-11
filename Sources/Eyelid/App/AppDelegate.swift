import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private let nowPlaying = NowPlayingService()
    private lazy var audioLevels = AudioLevels(settings: settings, nowPlaying: nowPlaying)
    private let battery = BatteryService()
    private lazy var output = OutputService(settings: settings)
    let shelf = Shelf()
    let clipboard = ClipboardHistory(pinnedFile: ClipboardHistory.defaultPinnedFile)
    private(set) lazy var translator = Translator(settings: settings)
    private let doubleCopy = DoubleCopyWatcher()
    private let appVolumes = AppVolumes()
    private let hotKeys = HotKeyCenter()
    private(set) lazy var clipboardShortcut = Shortcut(
        center: hotKeys,
        isEnabled: { [settings] in settings.clipboardEnabled },
        hotKey: { [settings] in settings.clipboardHotKey }
    )
    private(set) lazy var lidShortcut = Shortcut(
        center: hotKeys,
        isEnabled: { [settings] in settings.liveActivityShortcutEnabled },
        hotKey: { [settings] in settings.liveActivityHotKey }
    )
    private(set) lazy var translationShortcut = Shortcut(
        center: hotKeys,
        // On Macs that can't translate, ⌥T stays free.
        isEnabled: { [settings, translator] in settings.translationShortcutEnabled && translator.isAvailable },
        hotKey: { [settings] in settings.translationHotKey }
    )
    private lazy var hud = HUDService(settings: settings)
    private var notches: NotchCoordinator?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also covers `swift run`, where there is no Info.plist with LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        terminateGracefullyOnSignals()

        nowPlaying.start()
        audioLevels.start()
        battery.start()
        output.start()
        appVolumes.start()
        shelf.deleteUnusedPromisedFiles()
        notches = NotchCoordinator(
            nowPlaying: nowPlaying,
            audioLevels: audioLevels,
            battery: battery,
            output: output,
            shelf: shelf,
            clipboard: clipboard,
            clipboardShortcut: clipboardShortcut,
            lidShortcut: lidShortcut,
            translator: translator,
            appVolumes: appVolumes,
            doubleCopy: doubleCopy,
            translationShortcut: translationShortcut,
            hud: hud,
            settings: settings
        )
        followHUDSetting()
        followClipboardSetting()
        followTranslationSetting()
        followEqualizerSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
    }

    /// Turns key handling on and off as the setting changes.
    private func followHUDSetting() {
        withObservationTracking {
            hud.setEnabled(settings.replacesSystemHUD)
        } onChange: { [weak self] in
            // `onChange` runs before the new value is stored, so apply it on the next turn of the main actor.
            Task { @MainActor in
                self?.followHUDSetting()
            }
        }
    }

    /// Watches the pasteboard while the clipboard history is on.
    private func followClipboardSetting() {
        withObservationTracking {
            let isOn = settings.clipboardEnabled
            clipboard.setMonitoring(isOn)
            // macOS lists an app under Paste from Other Apps only once it has asked to read the pasteboard.
            // Reading it once does that, and its prompt tells the user what turning the history on means.
            if isOn, clipboard.access == .notAskedYet {
                clipboard.captureCurrentContents()
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followClipboardSetting()
            }
        }
    }

    /// While the equalizer follows the sound, macOS shows the recording indicator anyway, so every app playing goes
    /// through Eyelid, and changing an app's volume never switches its sound between paths.
    private func followEqualizerSetting() {
        withObservationTracking {
            appVolumes.routesPlayingApps = settings.equalizerFollowsAudio && AudioLevels.isSupported
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followEqualizerSetting()
            }
        }
    }

    /// Watches for text copied twice while that translates it, on Macs that can.
    private func followTranslationSetting() {
        withObservationTracking {
            doubleCopy.setWatching(settings.translatesOnDoubleCopy && translator.isAvailable)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followTranslationSetting()
            }
        }
    }

    /// `kill`, `pkill` and Ctrl-C skip `applicationWillTerminate`, which would leave the adapter process running.
    private func terminateGracefullyOnSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
