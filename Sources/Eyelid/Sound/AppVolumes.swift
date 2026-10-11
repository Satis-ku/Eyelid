import CoreAudio
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "AppVolume")

/// What plays an app at its own volume. `AppVolumeTap`, or a stand-in in tests.
@MainActor
protocol AppVolumeTapping: AnyObject {
    var processes: [AudioObjectID] { get }
    var outputUID: String { get }
    func setGain(_ value: Float)
    func stop()
}

@available(macOS 14.2, *)
extension AppVolumeTap: AppVolumeTapping {}

/// Each app's own volume, as SoundSource does it: an app below full volume plays through a tap of its own, at its
/// gain. Volumes are kept by app across launches, and taps follow the output and the app's processes.
@MainActor
@Observable
final class AppVolumes {
    /// What a tap is made for.
    struct Request {
        let processes: [AudioObjectID]
        let output: AudioDeviceID
        let outputUID: String
        let gain: Float
    }

    /// Whether this Mac can tap apps: macOS 14.2 and later.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    /// Volumes below full, by app. Apps at full volume aren't listed, and play as they do without Eyelid.
    private(set) var volumes: [String: Float]

    @ObservationIgnored private let defaults: any SettingsStore
    @ObservationIgnored private let apps: @MainActor () -> [AudioApp]
    @ObservationIgnored private let output: @MainActor () -> (AudioDeviceID, String)?
    @ObservationIgnored private let makeTap: @MainActor (Request) -> (any AppVolumeTapping)?
    @ObservationIgnored private(set) var taps: [String: any AppVolumeTapping] = [:]
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let key = "appVolumes"

    init(
        defaults: any SettingsStore = UserDefaults.standard,
        apps: @escaping @MainActor () -> [AudioApp] = AudioApps.all,
        output: @escaping @MainActor () -> (AudioDeviceID, String)? = AppVolumes.defaultOutput,
        makeTap: @escaping @MainActor (Request) -> (any AppVolumeTapping)? = AppVolumes.systemTap
    ) {
        self.defaults = defaults
        self.apps = apps
        self.output = output
        self.makeTap = makeTap
        let stored = defaults.object(forKey: Self.key) as? [String: Double] ?? [:]
        volumes = stored.mapValues(Float.init).filter { $0.value < 1 }
    }

    func volume(for app: AudioApp) -> Float {
        volumes[app.volumeKey] ?? 1
    }

    /// Sets an app's volume. While the slider moves, the tap only changes its gain; `sync` then settles which apps
    /// need one, so an app dragged back to full volume plays as it does without Eyelid.
    func setVolume(_ volume: Float, for app: AudioApp) {
        let volume = min(max(volume, 0), 1)
        let key = app.volumeKey
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

    /// Plays every app with a volume of its own through a tap on the current output, and the others as they are.
    func sync() {
        guard let (device, uid) = output() else {
            stopAll()
            return
        }
        var wanted: [String: AudioApp] = [:]
        for app in apps() where !app.processes.isEmpty {
            if volumes[app.volumeKey] != nil {
                wanted[app.volumeKey] = app
            }
        }

        for (key, tap) in taps {
            // A new output, or a helper that came or went, needs a new tap.
            if let app = wanted[key], tap.outputUID == uid, tap.processes == app.processes {
                continue
            }
            tap.stop()
            taps[key] = nil
        }
        for (key, app) in wanted where taps[key] == nil {
            let request = Request(processes: app.processes, output: device, outputUID: uid, gain: volumes[key] ?? 1)
            if let tap = makeTap(request) {
                taps[key] = tap
                logger.debug("Playing \(app.name, privacy: .public) at its own volume")
            }
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
            gain: request.gain
        )
    }
}
