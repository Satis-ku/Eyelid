import AppKit
import CoreAudio
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AudioTap")

/// The heights of the equalizer's bars, taken from the sound itself while that's turned on and something plays.
@MainActor
@Observable
final class AudioLevels {
    /// One level a bar, from 0 to 1. Nil while Eyelid isn't listening, or hears nothing at all, which is what it
    /// gets without the permission: the equalizer then moves on its own.
    private(set) var levels: [Double]?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let nowPlaying: NowPlayingService
    @ObservationIgnored private var tap: AnyObject?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var outputListener: AudioObjectPropertyListenerBlock?
    /// Since when the tap has heard only silence.
    @ObservationIgnored private var silentSince: ContinuousClock.Instant?
    /// Whether the displays are asleep, when nobody sees the equalizer.
    private(set) var isDisplayAsleep = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    /// How often the bars move, a second.
    static let frameRate = 30.0
    /// Rising bars follow quickly, falling ones settle more slowly, like a VU meter.
    nonisolated static let attack = 0.6
    nonisolated static let release = 0.22
    /// Silence this long, while something plays, means Eyelid isn't allowed to hear it.
    static let silenceTimeout: Duration = .seconds(2)

    init(settings: AppSettings, nowPlaying: NowPlayingService) {
        self.settings = settings
        self.nowPlaying = nowPlaying
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, isAsleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isDisplayAsleep = isAsleep
                }
            })
        }
        follow()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.outputChanged()
            }
        }
        var address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            outputListener = listener
        }
    }

    /// Whether the equalizer could be seen: the live activity is on and not hidden, and the displays are awake. When
    /// it can't, Eyelid doesn't listen to the system's sound for it, and macOS shows no recording indicator for it.
    var isEqualizerVisible: Bool {
        settings.showsLiveActivity && !settings.isLiveActivityHidden && !isDisplayAsleep
    }

    /// Not for a muted preview either, which reports playing but sends no sound, and doesn't show the equalizer.
    private var shouldListen: Bool {
        settings.equalizerFollowsAudio && isEqualizerVisible && nowPlaying.track?.isPlaying == true
            && !nowPlaying.isSilent
    }

    /// Listens while the setting is on and something plays, and not otherwise.
    private func follow() {
        withObservationTracking {
            setListening(shouldListen)
        } onChange: { [weak self] in
            // `onChange` runs before the new value is stored, so look again on the next turn of the main actor.
            Task { @MainActor in
                self?.follow()
            }
        }
    }

    private func setListening(_ isOn: Bool) {
        guard isOn != (tap != nil) else { return }
        guard isOn, #available(macOS 14.2, *) else {
            stopListening()
            return
        }

        let tap = SystemAudioTap()
        guard tap.start() else { return }
        self.tap = tap
        logger.debug("Listening for the equalizer")
        silentSince = nil
        pollTask = Task { [weak self] in
            while let interval = self?.pollInterval {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                self?.poll(tap)
            }
        }
    }

    private func stopListening() {
        if tap != nil {
            logger.debug("Stopped listening for the equalizer")
        }
        pollTask?.cancel()
        pollTask = nil
        if #available(macOS 14.2, *) {
            (tap as? SystemAudioTap)?.stop()
        }
        tap = nil
        levels = nil
    }

    /// A frame of the bars, or less often while all that's heard is silence and the bars move on their own.
    private var pollInterval: Duration {
        levels == nil && silentSince != nil ? .milliseconds(250) : .seconds(1 / Self.frameRate)
    }

    @available(macOS 14.2, *)
    private func poll(_ tap: SystemAudioTap) {
        // Copied inside the lock, so the tap never has to copy the array it writes to.
        let heard = tap.levels.withLock { $0.map(Double.init) }
        if heard.allSatisfy({ $0 == 0 }) {
            let now = ContinuousClock.now
            let since = silentSince ?? now
            silentSince = since
            if now - since >= Self.silenceTimeout {
                levels = nil
                return
            }
        } else {
            silentSince = nil
        }
        levels = Self.smooth(levels, toward: heard)
    }

    /// Moves the bars a step toward what's heard: quickly up, slowly down.
    nonisolated static func smooth(_ current: [Double]?, toward heard: [Double]) -> [Double] {
        guard let current, current.count == heard.count else { return heard }
        return zip(current, heard).map { shown, target in
            shown + (target - shown) * (target > shown ? attack : release)
        }
    }

    /// The tap listens through the default output, so it starts over on the new one.
    private func outputChanged() {
        guard tap != nil else { return }
        stopListening()
        Task { [weak self] in
            // The new output takes a moment to settle.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            setListening(shouldListen)
        }
    }
}
