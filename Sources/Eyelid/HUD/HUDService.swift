import AppKit
import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "HUD")

/// What the notch shows after a volume or brightness key.
struct HUDEvent: Equatable, Sendable {
    enum Kind: Sendable {
        case volume
        case brightness
    }

    var kind: Kind
    var level: Float
    var isMuted = false
    /// The output device's icon, for volume. `.speaker` draws waves that follow the level.
    var deviceIcon: DeviceIcon = .speaker
    /// For AirPods with one earbud in: that earbud, so the icon shows what's in use.
    var earbud: HeadphonesBattery.Earbud?

    var symbolName: String {
        switch kind {
        case .volume:
            if deviceIcon != .speaker {
                earbud.flatMap(deviceIcon.earbudSymbolName) ?? deviceIcon.availableSymbolName
            }
            else if isMuted || level == 0 { "speaker.slash.fill" }
            else if level < 1 / 3 { "speaker.wave.1.fill" }
            else if level < 2 / 3 { "speaker.wave.2.fill" }
            else { "speaker.wave.3.fill" }
        case .brightness:
            level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    /// Device icons have no muted variant, so they dim instead.
    var dimsIcon: Bool {
        kind == .volume && deviceIcon != .speaker && (isMuted || level == 0)
    }
}

/// Intercepts the volume and brightness keys: `MediaKeyTap` in the app, a stand-in in tests.
@MainActor
protocol KeyTap: AnyObject {
    var isRunning: Bool { get }
    /// Returns false without the Accessibility permission.
    func start() -> Bool
    func stop()
}

/// The Accessibility permission that the key tap needs: the system's in the app, a stand-in in tests.
struct AccessibilityAccess {
    var isGranted: @MainActor () -> Bool = { AXIsProcessTrusted() }
    /// Shows the system prompt that leads to the Accessibility list in System Settings.
    var request: @MainActor () -> Void = {
        // The key is kAXTrustedCheckOptionPrompt, which Swift 6 flags as a mutable global.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Replaces the system volume and brightness HUD: handles the keys itself and reports every change.
@MainActor
final class HUDService {
    var onEvent: (@MainActor (HUDEvent) -> Void)?

    private let settings: AppSettings
    private let access: AccessibilityAccess
    private var tap: (any KeyTap)!
    private var accessTask: Task<Void, Never>?
    private var hasRequestedAccess = false
    private let volumeWatcher: any VolumeWatching
    /// The volume Eyelid just set for a key, which the watcher hears about too.
    private var ownVolume: (state: SystemVolume.State, at: ContinuousClock.Instant)?

    /// How long after a key the watcher's report of the same volume is taken for Eyelid's own change.
    static let ownChangeWindow: Duration = .seconds(1)
    /// After the Accessibility list changes, the tap stays off this long before access is checked again.
    let accessSettleDelay: Duration

    private var isEnabled = false
    private var accessListObserver: NSObjectProtocol?
    /// Ends once access is checked again after the list changed; tests wait on it.
    private(set) var accessListTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        access: AccessibilityAccess = AccessibilityAccess(),
        makeTap: (@escaping @MainActor (MediaKeyPress) -> Bool) -> any KeyTap = { MediaKeyTap(handler: $0) },
        volumeWatcher: any VolumeWatching = VolumeWatcher(),
        accessSettleDelay: Duration = .milliseconds(500)
    ) {
        self.settings = settings
        self.accessSettleDelay = accessSettleDelay
        self.access = access
        self.volumeWatcher = volumeWatcher
        tap = makeTap { [weak self] press in
            self?.handle(press) ?? false
        }
        volumeWatcher.onChange = { [weak self] device, state in
            self?.volumeChangedElsewhere(device, state)
        }
        // macOS posts this whenever the Accessibility list in System Settings changes. Taking Eyelid's access away
        // while its tap runs can stall input across the Mac, so the tap stops at once, before any check.
        accessListObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accessibilityListChanged()
            }
        }
    }

    /// Stops the tap right away, then starts it again once access is settled, if Eyelid still has it.
    func accessibilityListChanged() {
        guard isEnabled else { return }
        if tap.isRunning {
            tap.stop()
            logger.info("The Accessibility list changed, so the key tap is off until access is checked again")
        }
        accessListTask?.cancel()
        accessListTask = Task { [weak self, accessSettleDelay] in
            try? await Task.sleep(for: accessSettleDelay)
            guard !Task.isCancelled else { return }
            self?.followAccess()
        }
    }

    /// Starts handling the keys, or waits for the Accessibility permission first.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        accessTask?.cancel()
        accessTask = nil
        accessListTask?.cancel()
        accessListTask = nil

        guard enabled else {
            tap.stop()
            volumeWatcher.stop()
            return
        }
        // Volume set without a key, from headphones for one, shows here too. macOS shows its own HUD for those as
        // well, since there's no key to hold back.
        volumeWatcher.start()

        if !tap.start() {
            logger.info("Waiting for Accessibility access to handle volume and brightness keys")
            // The ad hoc signature ties access to one build, so updates lose it too. Ask once per launch.
            if !hasRequestedAccess {
                hasRequestedAccess = true
                access.request()
            }
        }

        // Access is granted and taken away in System Settings, outside the app, so keep checking.
        accessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                followAccess()
            }
        }
    }

    /// Starts handling the keys once Accessibility access is granted, and stops as soon as it's taken away:
    /// macOS keeps sending events to a tap that has lost access, and input across the Mac stalls while it waits.
    func followAccess() {
        let isGranted = access.isGranted()
        if tap.isRunning, !isGranted {
            tap.stop()
            logger.info("Accessibility access was taken away, leaving volume and brightness keys to macOS")
        } else if !tap.isRunning, isGranted, tap.start() {
            logger.info("Accessibility access granted, handling volume and brightness keys")
        }
    }

    private func handle(_ press: MediaKeyPress) -> Bool {
        guard !press.opensSystemSettings else { return false }

        switch press.key {
        case .volumeUp, .volumeDown, .mute:
            return handleVolume(press)
        case .brightnessUp, .brightnessDown:
            return handleBrightness(press)
        }
    }

    // A key up is handled exactly when its key down would be, so macOS never sees half a press.

    private func handleVolume(_ press: MediaKeyPress) -> Bool {
        // Devices without a settable volume stay with macOS, which shows that it can't change them.
        guard let (device, state) = SystemVolume.read() else { return false }
        guard press.isKeyDown else { return true }

        let new = state.after(press.key, fine: press.isFineStep)
        guard SystemVolume.apply(new, from: state, on: device) else { return false }

        ownVolume = (new, .now)
        // The tap waits for this callback, and with it every key on the Mac. Reading the headphones' charge for the
        // HUD can take a while, so it happens after the key is handled.
        Task { @MainActor [weak self] in
            self?.showVolume(new, of: device)
        }
        return true
    }

    /// Volume changed without a key: from headphones, Control Center or another app.
    private func volumeChangedElsewhere(_ device: AudioDeviceID, _ state: SystemVolume.State) {
        if let ownVolume, ownVolume.state == state, ContinuousClock.now - ownVolume.at < Self.ownChangeWindow {
            return
        }
        showVolume(state, of: device)
    }

    private func showVolume(_ state: SystemVolume.State, of device: AudioDeviceID) {
        let output = OutputDevice(audioDevice: device)
        let deviceIcon = output.map(settings.icon(for:)) ?? .speaker
        let earbud = output.flatMap(HeadphonesBattery.current(for:))?.singleEarbud
        logger.debug("Volume \(state.level, privacy: .public), muted: \(state.isMuted, privacy: .public), icon: \(deviceIcon.rawValue, privacy: .public)")
        onEvent?(HUDEvent(kind: .volume, level: state.level, isMuted: state.isMuted, deviceIcon: deviceIcon, earbud: earbud))
    }

    private func handleBrightness(_ press: MediaKeyPress) -> Bool {
        guard let display = DisplayBrightness.builtInDisplay,
              let level = DisplayBrightness.level(of: display)
        else { return false }
        guard press.isKeyDown else { return true }

        let new = LevelStep.next(from: level, up: press.key == .brightnessUp, fine: press.isFineStep)
        guard DisplayBrightness.setLevel(new, of: display) else { return false }

        logger.debug("Brightness \(new, privacy: .public)")
        onEvent?(HUDEvent(kind: .brightness, level: new))
        return true
    }
}
