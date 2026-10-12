import AudioToolbox
import CoreAudio

/// The volume of the default output device, through CoreAudio.
enum SystemVolume {
    struct State: Equatable {
        var level: Float
        var isMuted: Bool

        /// The state after a key press. Volume keys unmute, as they do in macOS.
        func after(_ key: MediaKeyPress.Key, fine: Bool) -> State {
            switch key {
            case .mute:
                State(level: level, isMuted: !isMuted)
            case .volumeUp, .volumeDown:
                State(level: LevelStep.next(from: level, up: key == .volumeUp, fine: fine), isMuted: false)
            case .brightnessUp, .brightnessDown:
                self
            }
        }
    }

    /// Nil when there is no output device, or its volume can't be set, as with many HDMI outputs.
    static func read() -> (device: AudioDeviceID, state: State)? {
        guard let device = AudioProperty.defaultOutputDevice(),
              AudioProperty.isSettable(volumeAddress, of: device),
              let level: Float32 = AudioProperty.value(volumeAddress, of: device)
        else { return nil }

        let muted: UInt32 = AudioProperty.value(muteAddress, of: device) ?? 0
        return (device, State(level: level, isMuted: muted != 0))
    }

    /// Returns false if the device rejected the change.
    static func apply(_ state: State, from old: State, on device: AudioDeviceID) -> Bool {
        if state.level != old.level, !AudioProperty.set(Float32(state.level), volumeAddress, of: device) {
            return false
        }
        if state.isMuted != old.isMuted {
            guard AudioProperty.isSettable(muteAddress, of: device) else { return false }
            return AudioProperty.set(UInt32(state.isMuted ? 1 : 0), muteAddress, of: device)
        }
        return true
    }

    static let volumeAddress = AudioProperty.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyScopeOutput
    )

    static let muteAddress = AudioProperty.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
}
