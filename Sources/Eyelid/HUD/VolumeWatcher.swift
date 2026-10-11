import CoreAudio
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "HUD")

/// Notices changes to the volume of the default output, `VolumeWatcher` in the app, a stand-in in tests.
@MainActor
protocol VolumeWatching: AnyObject {
    var onChange: (@MainActor (AudioDeviceID, SystemVolume.State) -> Void)? { get set }
    func start()
    func stop()
}

/// Notices changes to the volume of the default output, whoever makes them: headphones, which set it over Bluetooth
/// rather than with a key, Control Center, or other apps.
@MainActor
final class VolumeWatcher: VolumeWatching {
    var onChange: (@MainActor (AudioDeviceID, SystemVolume.State) -> Void)?

    /// After the output changes, its new volume isn't a change, and headphones often set theirs as they connect.
    static let quietAfterSwitch: Duration = .seconds(1.5)

    private var device: AudioDeviceID?
    private var lastState: SystemVolume.State?
    private var quietUntil: ContinuousClock.Instant?
    private var deviceListeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// A listener the HAL queued already still runs after `stop`, so each checks this first.
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.followDefaultOutput()
            }
        }
        var address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            outputListener = listener
        }
        followDefaultOutput(isSwitch: false)
    }

    func stop() {
        isRunning = false
        if let outputListener {
            var address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
        outputListener = nil
        detach()
    }

    private func followDefaultOutput(isSwitch: Bool = true) {
        guard isRunning else { return }
        let current = AudioProperty.defaultOutputDevice()
        guard current != device else { return }
        detach()
        device = current
        lastState = SystemVolume.read().flatMap { $0.device == current ? $0.state : nil }
        if isSwitch {
            quietUntil = .now + Self.quietAfterSwitch
        }
        guard let current else { return }

        for address in [SystemVolume.volumeAddress, SystemVolume.muteAddress] {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.volumeChanged()
                }
            }
            var address = address
            if AudioObjectAddPropertyListenerBlock(current, &address, .main, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
    }

    private func detach() {
        if let device {
            for (address, block) in deviceListeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            }
        }
        deviceListeners = []
        device = nil
    }

    private func volumeChanged() {
        guard isRunning, let (device, state) = SystemVolume.read(), device == self.device, state != lastState else { return }
        lastState = state
        if let quietUntil, ContinuousClock.now < quietUntil {
            return
        }
        logger.debug("Volume changed outside Eyelid: \(state.level, privacy: .public), muted: \(state.isMuted, privacy: .public)")
        onChange?(device, state)
    }
}
