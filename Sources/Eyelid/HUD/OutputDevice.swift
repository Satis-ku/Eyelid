import CoreAudio

/// An audio output device, as CoreAudio describes it.
struct OutputDevice: Equatable, Identifiable, Sendable {
    enum Transport: Equatable, Sendable {
        case builtIn
        case bluetooth
        case usb
        case hdmi
        case displayPort
        case airPlay
        case other
    }

    /// CoreAudio's UID, which stays the same across reconnects. Bluetooth devices use their address.
    let id: String
    let name: String
    let transport: Transport
    /// For the built-in output: wired headphones are plugged in, so the speakers are off.
    let isHeadphoneJack: Bool
    /// For Bluetooth devices, the product and vendor ID in hex, such as "2024 4c" for AirPods Pro 2.
    let modelUID: String?

    /// The product ID of Apple and Beats Bluetooth devices, whose vendor ID is 0x4C.
    var appleProductID: Int? {
        let parts = modelUID?.split(separator: " ") ?? []
        guard parts.count == 2, Int(parts[1], radix: 16) == 0x4C else { return nil }
        return Int(parts[0], radix: 16)
    }
}

extension OutputDevice {
    init?(audioDevice device: AudioDeviceID) {
        guard let id = AudioProperty.string(AudioProperty.address(kAudioDevicePropertyDeviceUID), of: device) else { return nil }

        let transport: UInt32 = AudioProperty.value(AudioProperty.address(kAudioDevicePropertyTransportType), of: device) ?? 0
        let dataSource: UInt32? = AudioProperty.value(
            AudioProperty.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput),
            of: device
        )

        self.init(
            id: id,
            name: AudioProperty.string(AudioProperty.address(kAudioObjectPropertyName), of: device) ?? "Unknown device",
            transport: Transport(coreAudio: transport),
            isHeadphoneJack: dataSource == UInt32(fourCharacterCode: "hdpn"),
            modelUID: AudioProperty.string(AudioProperty.address(kAudioDevicePropertyModelUID), of: device)
        )
    }

    /// The start of the UIDs of the devices Eyelid makes for itself, such as the equalizer's tap. Their own process
    /// sees them, so they're left out of every list.
    static let ownDevicePrefix = "io.github.satis-ku.eyelid."

    /// Every visible device that can play sound, the default one first. Not the devices Eyelid makes for itself.
    static func all() -> [OutputDevice] {
        let devices: [AudioDeviceID] = AudioProperty.array(
            AudioProperty.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID(kAudioObjectSystemObject)
        )
        let defaultDevice = AudioProperty.defaultOutputDevice()

        return devices
            .filter { device in
                let streams: [AudioStreamID] = AudioProperty.array(
                    AudioProperty.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
                    of: device
                )
                let hidden: UInt32 = AudioProperty.value(AudioProperty.address(kAudioDevicePropertyIsHidden), of: device) ?? 0
                return !streams.isEmpty && hidden == 0
            }
            .sorted { $0 == defaultDevice && $1 != defaultDevice }
            .compactMap(OutputDevice.init(audioDevice:))
            .filter { !$0.id.hasPrefix(ownDevicePrefix) }
    }
}

extension OutputDevice.Transport {
    init(coreAudio transport: UInt32) {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        default: self = .other
        }
    }
}
