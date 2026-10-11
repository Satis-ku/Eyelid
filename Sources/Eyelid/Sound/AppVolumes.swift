import CoreAudio
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AppVolume")

/// What plays an app at its own volume. `AppVolumeTap`, or a stand-in in tests.
@MainActor
protocol AppVolumeTapping: AnyObject {
    var processes: [AudioObjectID] { get }
    var outputUID: String { get }
    /// Whether it plays the app now, rather than only keeping it muted.
    var isRunning: Bool { get }
    /// How long it has heard only silence, from its start, or nil once it has heard anything.
    var silence: Duration? { get }
    func setGain(_ value: Float)
    func setEqualizer(_ settings: EqualizerSettings)
    func setRunning(_ running: Bool)
    /// Whether macOS keeps the app's sound from Eyelid.
    func isHearingDenied() -> Bool
    func stop()
}

@available(macOS 14.2, *)
extension AppVolumeTap: AppVolumeTapping {}

/// Each app's own volume, as SoundSource does it: an app below full volume plays through a tap of its own, at its
/// gain. Volumes are kept by app across launches, and taps follow the output and the app's processes.
///
/// Switching an app between its own output and a tap leaves a gap of a few milliseconds, since the two paths have
/// different latencies. So switches happen where they can't be heard when they can: an app back at full volume keeps
/// its tap until it's quiet. And while `routesPlayingApps` is on, every app playing goes through a tap from its first
/// sound, so turning it down or up never switches anything.
///
/// A tap plays its app while the app plays and for `quietGrace` after, so a pause doesn't cut anything; then it only
/// keeps the app muted, and the output, and the Mac, can sleep.
@MainActor
@Observable
final class AppVolumes {
    /// What a tap is made for.
    struct Request {
        let processes: [AudioObjectID]
        let output: AudioDeviceID
        let outputUID: String
        let gain: Float
        let equalizer: EqualizerSettings
        let isRunning: Bool
    }

    /// Whether this Mac can tap apps: macOS 14.2 and later.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    /// Volumes below full, by app. Apps at full volume aren't listed, and play as they do without Eyelid.
    private(set) var volumes: [String: Float]
    /// Equalizers that aren't flat, by app. An app with one plays through a tap, as one turned down does.
    private(set) var equalizers: [String: EqualizerSettings]
    /// Whether macOS doesn't let Eyelid hear apps, so their taps would keep them silent. Apps then play as they do
    /// without Eyelid, until a volume or an equalizer is changed again.
    private(set) var isHearingDenied = false

    /// Whether every app playing goes through a tap, at full volume unless turned down. On while the equalizer
    /// follows the sound, since macOS shows the recording indicator then anyway. A tap stays `quietGrace` after its
    /// app goes quiet, so a pause doesn't switch, and then goes, so the output can sleep.
    @ObservationIgnored private(set) var routesPlayingApps = false

    /// Starts or stops routing every app playing. Stopping, such as by hiding the live activity, is to stop
    /// listening, so the taps go at once, but for apps with settings of their own. Unless `whenQuiet`, as while the
    /// displays sleep and nobody sees the recording indicator: then each goes once its app is quiet, so the sound
    /// doesn't switch paths while it plays.
    func setRoutesPlayingApps(_ isOn: Bool, whenQuiet: Bool = false) {
        guard isOn != routesPlayingApps else { return }
        routesPlayingApps = isOn
        if !isOn, !whenQuiet {
            for (key, tap) in taps where !hasOwnSettings(key) {
                tap.stop()
                taps[key] = nil
            }
        }
        sync()
    }

    @ObservationIgnored private let defaults: any SettingsStore
    @ObservationIgnored private let apps: @MainActor () -> [AudioApp]
    @ObservationIgnored private let output: @MainActor () -> (AudioDeviceID, String)?
    @ObservationIgnored private let makeTap: @MainActor (Request) -> (any AppVolumeTapping)?
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private(set) var taps: [String: any AppVolumeTapping] = [:]
    /// When each app was last heard playing.
    @ObservationIgnored private var lastHeard: [String: ContinuousClock.Instant] = [:]
    /// Since when each app playing has played without a break.
    @ObservationIgnored private var playingSince: [String: ContinuousClock.Instant] = [:]
    /// Taps already asked whether macOS lets Eyelid hear their app. Asking can interrupt the sound, so once is enough.
    @ObservationIgnored private var askedTaps = Set<ObjectIdentifier>()
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Listeners on each process for its sound starting and stopping, by process.
    @ObservationIgnored private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// Looks again later: for apps gone quiet, and a tap's grace running out.
    @ObservationIgnored private(set) var checkTask: Task<Void, Never>?
    /// When `checkTask` looks again, from the last `sync`.
    @ObservationIgnored private(set) var checkDelay: Duration?
    /// How often it looks while an app with a tap plays; five times less often while none does. Tests shorten it.
    @ObservationIgnored let checkInterval: Duration
    @ObservationIgnored let quietGrace: Duration
    /// Silence this long from a tap, while its app plays, may mean Eyelid isn't allowed to hear it.
    static let silenceTimeout: Duration = .seconds(4)

    private static let key = "appVolumes"
    private static let equalizersKey = "appEqualizers"

    init(
        defaults: any SettingsStore = UserDefaults.standard,
        apps: @escaping @MainActor () -> [AudioApp] = { AudioApps.all() },
        output: @escaping @MainActor () -> (AudioDeviceID, String)? = AppVolumes.defaultOutput,
        makeTap: @escaping @MainActor (Request) -> (any AppVolumeTapping)? = AppVolumes.systemTap,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        checkInterval: Duration = .seconds(2),
        quietGrace: Duration = .seconds(5 * 60)
    ) {
        self.defaults = defaults
        self.apps = apps
        self.output = output
        self.makeTap = makeTap
        self.now = now
        self.checkInterval = checkInterval
        self.quietGrace = quietGrace
        let stored = defaults.object(forKey: Self.key) as? [String: Double] ?? [:]
        volumes = stored.mapValues(Float.init).filter { $0.value < 1 }
        equalizers = (defaults.object(forKey: Self.equalizersKey) as? Data)
            .flatMap { try? JSONDecoder().decode([String: EqualizerSettings].self, from: $0) }?
            .filter { !$0.value.isFlat } ?? [:]
    }

    func equalizer(for app: AudioApp) -> EqualizerSettings {
        equalizers[app.volumeKey] ?? .flat
    }

    /// Sets an app's equalizer. A flat one is forgotten, and the app plays as it does without Eyelid once it's quiet.
    func setEqualizer(_ settings: EqualizerSettings, for app: AudioApp) {
        let key = app.volumeKey
        isHearingDenied = false
        equalizers[key] = settings.isFlat ? nil : settings
        defaults.set(try? JSONEncoder().encode(equalizers), forKey: Self.equalizersKey)
        if let tap = taps[key] {
            tap.setEqualizer(settings)
        } else if !settings.isFlat {
            sync()
        }
    }

    /// Whether an app needs a tap for its own settings, whatever else plays.
    private func hasOwnSettings(_ key: String) -> Bool {
        volumes[key] != nil || equalizers[key] != nil
    }

    func volume(for app: AudioApp) -> Float {
        volumes[app.volumeKey] ?? 1
    }

    /// Sets an app's volume. While the slider moves, the tap only changes its gain; `sync` then settles which apps
    /// need one.
    func setVolume(_ volume: Float, for app: AudioApp) {
        let volume = min(max(volume, 0), 1)
        let key = app.volumeKey
        isHearingDenied = false
        volumes[key] = volume < 1 ? volume : nil
        defaults.set(volumes.mapValues(Double.init), forKey: Self.key)
        if let tap = taps[key] {
            tap.setGain(volume)
        } else if volume < 1 {
            sync()
        }
    }

    /// Starts following the apps' processes and the output.
    func start() {
        guard Self.isSupported else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            let address = AudioProperty.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.sync()
                }
            }
            var registered = address
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &registered, .main, listener)
            if status == noErr {
                listeners.append((address, listener))
            }
        }
        sync()
    }

    /// Gives a tap to every app that needs one on the current output, and takes it from the others once that can't
    /// be heard. Each tap plays its app only while that can be heard.
    func sync() {
        let now = now()
        guard isWatching, let (device, uid) = output() else {
            stopAll()
            watchProcesses([])
            scheduleCheck(at: now)
            return
        }
        let current = Self.oneForEachKey(apps())
        var wanted: [String: AudioApp] = [:]
        var kept: [String: AudioApp] = [:]
        var playing: [String: ContinuousClock.Instant] = [:]
        for app in current where !app.processes.isEmpty {
            let key = app.volumeKey
            if app.isPlaying {
                lastHeard[key] = now
                playing[key] = playingSince[key] ?? now
            }
            if hasOwnSettings(key) || (routesPlayingApps && app.isPlaying) {
                wanted[key] = app
            } else if taps[key] != nil, app.isPlaying || (routesPlayingApps && isAudible(key, at: now)) {
                kept[key] = app
            }
        }
        playingSince = playing
        lastHeard = lastHeard.filter { now - $0.value < quietGrace }

        for (key, tap) in taps {
            // A new output, or a helper that came or went, needs a new tap, unless the app doesn't need one anymore.
            if let app = wanted[key] ?? kept[key], tap.outputUID == uid, tap.processes == app.processes {
                tap.setRunning(isAudible(key, at: now))
                continue
            }
            tap.stop()
            taps[key] = nil
        }
        for (key, app) in wanted where taps[key] == nil {
            let request = Request(
                processes: app.processes,
                output: device,
                outputUID: uid,
                gain: volumes[key] ?? 1,
                equalizer: equalizers[key] ?? .flat,
                isRunning: isAudible(key, at: now)
            )
            if let tap = makeTap(request) {
                taps[key] = tap
                logger.debug("Playing \(app.name, privacy: .public) through Eyelid")
            }
        }
        if isHearingDeniedByAnyTap(at: now) {
            logger.error("macOS doesn't let Eyelid hear apps, so they play as they do without it")
            isHearingDenied = true
            sync()
            return
        }

        watchProcesses(current.flatMap(\.processes))
        scheduleCheck(at: now)
    }

    /// Apps by what their settings are kept by: two copies of an app running share one tap, with both's processes.
    private static func oneForEachKey(_ apps: [AudioApp]) -> [AudioApp] {
        var merged: [String: AudioApp] = [:]
        var order: [String] = []
        for app in apps {
            let key = app.volumeKey
            if var known = merged[key] {
                known.processes += app.processes
                known.isPlaying = known.isPlaying || app.isPlaying
                merged[key] = known
            } else {
                merged[key] = app
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Whether there's anything to do: apps with settings of their own, or every app playing to route.
    private var isWatching: Bool {
        !isHearingDenied && (routesPlayingApps || !volumes.isEmpty || !equalizers.isEmpty || !taps.isEmpty)
    }

    /// Whether an app plays, or did a moment ago: within `quietGrace`.
    private func isAudible(_ key: String, at now: ContinuousClock.Instant) -> Bool {
        guard let heard = lastHeard[key] else { return false }
        return now - heard < quietGrace
    }

    /// Asks macOS, once a tap, whether it keeps an app's sound from Eyelid, when the tap has heard only silence while
    /// its app played. Silence alone may just be an app playing nothing, such as a browser with a page that might.
    private func isHearingDeniedByAnyTap(at now: ContinuousClock.Instant) -> Bool {
        askedTaps.formIntersection(taps.values.map(ObjectIdentifier.init))
        for (key, tap) in taps where !askedTaps.contains(ObjectIdentifier(tap)) {
            guard let since = playingSince[key], now - since >= Self.silenceTimeout,
                  let silence = tap.silence, silence >= Self.silenceTimeout
            else { continue }
            askedTaps.insert(ObjectIdentifier(tap))
            if tap.isHearingDenied() {
                return true
            }
        }
        return false
    }

    /// Hears each process start and stop sending sound, so a playing app gets its tap from its first sound.
    private func watchProcesses(_ processes: [AudioObjectID]) {
        guard Self.isSupported else { return }
        let address = AudioProperty.address(kAudioProcessPropertyIsRunningOutput)
        let current = Set(processes)
        for (process, listener) in processListeners where !current.contains(process) {
            var registered = address
            AudioObjectRemovePropertyListenerBlock(process, &registered, .main, listener)
            processListeners[process] = nil
        }
        for process in current where processListeners[process] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.sync()
                }
            }
            var registered = address
            if AudioObjectAddPropertyListenerBlock(process, &registered, .main, listener) == noErr {
                processListeners[process] = listener
            }
        }
    }

    /// Looks again while there are taps: often while an app with one plays, when a quiet app's grace runs out, and
    /// now and then otherwise. The listeners should catch apps starting and stopping, and this makes sure, since an
    /// app whose tap isn't running stays muted.
    private func scheduleCheck(at now: ContinuousClock.Instant) {
        checkTask?.cancel()
        checkTask = nil
        checkDelay = nil
        guard isWatching else { return }
        let idle = checkInterval * 5
        var delay: Duration?
        for (key, tap) in taps {
            var due = idle
            if playingSince[key] != nil {
                due = checkInterval
            } else if tap.isRunning, let heard = lastHeard[key] {
                due = min(due, max(heard + quietGrace - now, .zero))
            }
            delay = min(delay ?? due, due)
        }
        guard let delay else { return }
        checkDelay = delay
        checkTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay, tolerance: delay / 10)
            } catch {
                return
            }
            guard let self else { return }
            checkTask = nil
            sync()
        }
    }

    private func stopAll() {
        for tap in taps.values {
            tap.stop()
        }
        taps = [:]
    }

    // MARK: - The system's

    static func defaultOutput() -> (AudioDeviceID, String)? {
        guard let device = AudioProperty.defaultOutputDevice(),
              let uid = AudioProperty.string(AudioProperty.address(kAudioDevicePropertyDeviceUID), of: device),
              // Eyelid's own aggregate devices are never an output to play through.
              !uid.hasPrefix(OutputDevice.ownDevicePrefix)
        else { return nil }
        return (device, uid)
    }

    static func systemTap(_ request: Request) -> (any AppVolumeTapping)? {
        guard #available(macOS 14.2, *) else { return nil }
        return AppVolumeTap(
            processes: request.processes,
            output: request.output,
            outputUID: request.outputUID,
            gain: request.gain,
            equalizer: request.equalizer,
            isRunning: request.isRunning
        )
    }
}
