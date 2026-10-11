import CoreAudio
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Sound")

/// The volume and the outputs, for the Sound tab: read while the tab shows, and changed from it.
@MainActor
@Observable
final class SoundControl {
    /// Every output that can play sound, the default one first.
    private(set) var devices: [OutputDevice] = []
    private(set) var defaultDeviceID: String?
    private(set) var volume = SystemVolume.State(level: 0, isMuted: false)
    /// False for outputs whose volume can't be set, as with many HDMI displays.
    private(set) var canSetVolume = false
    /// The apps sending sound right now.
    private(set) var apps: [AudioApp] = []
    /// While the slider is dragged, reading the volume back would make it jump.
    var isAdjusting = false

    /// Reads everything again. Cheap: a few Core Audio queries. Only what changed is set, so the panel redraws only
    /// then, and app icons load only for apps new to the list.
    func refresh() {
        update(\.devices, to: OutputDevice.all())
        let playing = AudioApps.all().filter(\.isPlaying)
        if playing != apps {
            apps = AudioApps.withIcons(playing, from: apps)
        }
        update(\.defaultDeviceID, to: AudioProperty.defaultOutputDevice().flatMap(OutputDevice.init(audioDevice:))?.id)
        guard !isAdjusting else { return }
        if let (_, state) = SystemVolume.read() {
            update(\.volume, to: state)
            update(\.canSetVolume, to: true)
        } else {
            update(\.canSetVolume, to: false)
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SoundControl, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    func setLevel(_ level: Float) {
        guard let (device, current) = SystemVolume.read() else { return }
        let new = SystemVolume.State(level: min(max(level, 0), 1), isMuted: false)
        if SystemVolume.apply(new, from: current, on: device) {
            volume = new
        }
    }

    func toggleMute() {
        guard let (device, current) = SystemVolume.read() else { return }
        let new = SystemVolume.State(level: current.level, isMuted: !current.isMuted)
        if SystemVolume.apply(new, from: current, on: device) {
            volume = new
        }
    }

    /// Makes this output the default one, as the Sound menu in Control Center does.
    func select(_ device: OutputDevice) {
        let audioDevices: [AudioDeviceID] = AudioProperty.array(
            AudioProperty.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID(kAudioObjectSystemObject)
        )
        guard let audioDevice = audioDevices.first(where: { OutputDevice(audioDevice: $0)?.id == device.id }) else { return }
        let address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioProperty.set(audioDevice, address, of: AudioObjectID(kAudioObjectSystemObject)) {
            logger.debug("Switched to \(device.name, privacy: .public)")
        } else {
            logger.error("Could not switch to \(device.name, privacy: .public)")
        }
        refresh()
    }
}
