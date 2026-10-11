import AppKit

/// The icon the volume HUD shows for an output device. Users can pick one per device in Settings.
enum DeviceIcon: String, CaseIterable, Sendable {
    /// Speaker waves that follow the volume, like the system HUD.
    case speaker
    case laptop
    case headphones
    case earbuds
    case headset
    case airpods
    case airpods3
    case airpods4
    case airpodsPro
    case airpodsMax
    case beatsHeadphones
    case beatsEarbuds
    case hifiSpeaker
    case homePod
    case display
    case tv
    case airPlay
    case car

    var title: String {
        switch self {
        case .speaker: "Speaker"
        case .laptop: "MacBook"
        case .headphones: "Headphones"
        case .earbuds: "Earbuds"
        case .headset: "Headset"
        case .airpods: "AirPods"
        case .airpods3: "AirPods (3rd generation)"
        case .airpods4: "AirPods 4"
        case .airpodsPro: "AirPods Pro"
        case .airpodsMax: "AirPods Max"
        case .beatsHeadphones: "Beats headphones"
        case .beatsEarbuds: "Beats earbuds"
        case .hifiSpeaker: "Speakers"
        case .homePod: "HomePod"
        case .display: "Display"
        case .tv: "TV"
        case .airPlay: "AirPlay"
        case .car: "Car"
        }
    }

    var symbolName: String {
        switch self {
        case .speaker: "speaker.wave.2.fill"
        case .laptop: "laptopcomputer"
        case .headphones: "headphones"
        case .earbuds: "earbuds"
        case .headset: "headset"
        case .airpods: "airpods"
        case .airpods3: "airpods.gen3"
        case .airpods4: "airpods.gen4"
        case .airpodsPro: "airpods.pro"
        case .airpodsMax: "airpods.max"
        case .beatsHeadphones: "beats.headphones"
        case .beatsEarbuds: "beats.studiobuds"
        case .hifiSpeaker: "hifispeaker.fill"
        case .homePod: "homepod.fill"
        case .display: "display"
        case .tv: "tv.fill"
        case .airPlay: "airplayaudio"
        case .car: "car.fill"
        }
    }

    /// Newer symbols, such as AirPods 4, don't exist on older macOS versions. Those get plain headphones.
    var availableSymbolName: String {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil ? symbolName : "headphones"
    }

    /// The icon to use when the user hasn't picked one.
    static func automatic(for device: OutputDevice) -> DeviceIcon {
        switch device.transport {
        case .builtIn: device.isHeadphoneJack ? .headphones : .speaker
        case .bluetooth: appleHeadphones(for: device) ?? .headphones
        case .hdmi: .tv
        case .displayPort: .display
        case .airPlay: .airPlay
        case .usb, .other: .speaker
        }
    }

    /// AirPods and Beats, by product ID where it's known for sure, and by their default name otherwise.
    private static func appleHeadphones(for device: OutputDevice) -> DeviceIcon? {
        if let product = device.appleProductID, let icon = appleProducts[product] {
            return icon
        }

        let name = device.name.lowercased()
        if name.contains("airpods max") { return .airpodsMax }
        if name.contains("airpods pro") { return .airpodsPro }
        if name.contains("airpods 4") { return .airpods4 }
        if name.contains("airpods") { return .airpods }
        if ["buds", "powerbeats", "fit pro", "flex"].contains(where: name.contains) { return .beatsEarbuds }
        if name.contains("beats") { return .beatsHeadphones }
        return nil
    }

    /// Product IDs as CoreAudio's model UID reports them, such as "2024 4c" for AirPods Pro 2 with USB-C.
    private static let appleProducts: [Int: DeviceIcon] = [
        0x2002: .airpods, // 1st generation
        0x200F: .airpods, // 2nd generation
        0x2013: .airpods3,
        0x200E: .airpodsPro,
        0x2014: .airpodsPro, // 2nd generation, Lightning
        0x2024: .airpodsPro, // 2nd generation, USB-C
        0x200A: .airpodsMax,
    ]
}

extension DeviceIcon {
    /// One earbud of the pair, for when only that one is in use. Nil for headphones that aren't earbuds.
    func earbudSymbolName(_ earbud: HeadphonesBattery.Earbud) -> String? {
        let side = earbud == .left ? "left" : "right"
        let name: String? = switch self {
        case .airpods: "airpod.\(side)"
        // AirPods 4 have the shape of the third generation, and no symbols of their own for one earbud.
        case .airpods3, .airpods4: "airpod.gen3.\(side)"
        case .airpodsPro: "airpodpro.\(side)"
        case .beatsEarbuds: "beats.studiobud.\(side)"
        default: nil
        }
        return name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 }
    }
}
