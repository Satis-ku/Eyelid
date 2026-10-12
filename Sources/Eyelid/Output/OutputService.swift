import CoreAudio
import Foundation
import notify
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Output")

/// Shows where sound goes: the new output whenever it switches, and the earbuds in use as they go in and out of the
/// case.
@MainActor
final class OutputService {
    var onEvent: (@MainActor (OutputEvent) -> Void)?

    private let settings: AppSettings
    /// The output sound went to at the last look, so only a switch counts.
    private var defaultDeviceID: String?
    private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []
    private var switchTask: Task<Void, Never>?
    /// Connected Apple and Beats headphones, which report which earbuds are out of the case.
    private var appleHeadphones: [OutputDevice] = []
    /// The earbuds out of the case at the last look, by device. Missing until the switch to them has shown.
    private var earbudsInUse: [String: Set<HeadphonesBattery.Earbud>] = [:]
    private var watchTask: Task<Void, Never>?
    private var notifyTokens: [Int32] = []

    /// macOS can switch several times in a row as headphones connect. The notch shows where it settles.
    private static let switchSettleDelay: Duration = .milliseconds(150)
    /// AirPods report their charge a moment after connecting, if macOS doesn't know it already. Until they do, the
    /// notch waits and looks again, so the icon and the charge show up together.
    private static let batteryPollInterval: Duration = .milliseconds(200)
    /// Apple headphones that haven't reported a charge by then show up with their volume instead.
    private static let batteryWait: Duration = .seconds(3)
    /// macOS posts these when an accessory's power sources change, such as an earbud going in or out of the case.
    /// The names are IOKit's, from its private headers.
    private static let accessoryNotifications = [
        "com.apple.system.accpowersources.attach",
        "com.apple.system.accpowersources.timeremaining",
    ]
    /// In case a notification goes missing, a look every so often while headphones are connected. Each look is a
    /// local IOKit call.
    private static let earbudsInterval: Duration = .seconds(2)

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        defaultDeviceID = Self.defaultOutput()?.id
        followActivitySetting()
        for device in appleHeadphones {
            earbudsInUse[device.id] = HeadphonesBattery.current(for: device)?.earbudsInUse
        }

        listen(to: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.defaultOutputChanged()
        }
        listen(to: kAudioHardwarePropertyDevices) { [weak self] in
            self?.followAppleHeadphones(in: OutputDevice.all())
        }
        for name in Self.accessoryNotifications {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkEarbuds()
                }
            }
            if status == NOTIFY_STATUS_OK {
                notifyTokens.append(token)
            }
        }
    }

    private func listen(to selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var address = AudioProperty.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Runs on the main queue, as passed below.
            MainActor.assumeIsolated {
                handler()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            listeners.append((selector, block))
        } else {
            logger.error("Could not watch audio property \(selector, privacy: .public): \(status, privacy: .public)")
        }
    }

    private static func defaultOutput() -> OutputDevice? {
        AudioProperty.defaultOutputDevice().flatMap(OutputDevice.init(audioDevice:))
    }

    // MARK: - Switching outputs

    private func defaultOutputChanged() {
        followAppleHeadphones(in: OutputDevice.all())
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.switchSettleDelay)
            guard !Task.isCancelled else { return }
            await self?.showDefaultOutput()
        }
    }

    private func showDefaultOutput() async {
        guard let device = Self.defaultOutput(), device.id != defaultDeviceID else { return }
        defaultDeviceID = device.id
        guard settings.outputActivityEnabled else { return }
        logger.debug("Switched to \(device.name, privacy: .public)")

        var event = OutputEvent(deviceID: device.id, name: device.name, icon: settings.icon(for: device))
        if device.transport == .bluetooth, let productID = device.appleProductID {
            event.battery = await Self.waitForBattery(of: device, productID: productID)
            guard !Task.isCancelled else { return }
            earbudsInUse[device.id] = event.battery?.earbudsInUse ?? []
        }
        if event.battery == nil {
            event.volume = SystemVolume.read()?.state
        }
        onEvent?(event)
    }

    /// Looks until an earbud is out of the case: right after connecting, macOS may still list both in it.
    private static func waitForBattery(of device: OutputDevice, productID: Int) async -> HeadphonesBattery? {
        let deadline = ContinuousClock.now + batteryWait
        var battery: HeadphonesBattery?
        while ContinuousClock.now < deadline, !Task.isCancelled {
            battery = HeadphonesBattery(
                powerSources: AccessoryPowerSources.descriptions(),
                deviceName: device.name,
                productID: productID
            )
            if battery?.isInUse == true { break }
            try? await Task.sleep(for: batteryPollInterval)
        }
        logger.debug("Battery: \(String(describing: battery), privacy: .public)")
        return battery
    }

    // MARK: - Earbuds going in and out

    /// Looks at the earbuds every so often only while the notch shows them going in and out.
    private func followActivitySetting() {
        withObservationTracking {
            followAppleHeadphones(in: OutputDevice.all())
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followActivitySetting()
            }
        }
    }

    /// Watches the connected Apple and Beats headphones, and stops once there are none.
    private func followAppleHeadphones(in devices: [OutputDevice]) {
        appleHeadphones = devices.filter { $0.transport == .bluetooth && $0.appleProductID != nil }
        let connected = Set(appleHeadphones.map(\.id))
        earbudsInUse = earbudsInUse.filter { connected.contains($0.key) }

        guard !appleHeadphones.isEmpty, settings.outputActivityEnabled else {
            watchTask?.cancel()
            watchTask = nil
            return
        }
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: Self.earbudsInterval, tolerance: .milliseconds(500))
                } catch {
                    return
                }
                self?.checkEarbuds()
            }
        }
    }

    /// Shows the headphones again when an earbud goes in or out of the case, so the notch shows what's in use.
    private func checkEarbuds() {
        for device in appleHeadphones {
            guard let previous = earbudsInUse[device.id],
                  let battery = HeadphonesBattery.current(for: device)
            else { continue }
            let current = battery.earbudsInUse
            earbudsInUse[device.id] = current
            guard Self.isWorthShowing(from: previous, to: current), settings.outputActivityEnabled else { continue }

            logger.debug("Earbuds in use: \(current.count, privacy: .public)")
            onEvent?(OutputEvent(deviceID: device.id, name: device.name, icon: settings.icon(for: device), battery: battery))
        }
    }

    /// One earbud in, the second one joining, or one leaving. Not both going back in the case, which disconnects them.
    nonisolated static func isWorthShowing(
        from previous: Set<HeadphonesBattery.Earbud>,
        to current: Set<HeadphonesBattery.Earbud>
    ) -> Bool {
        current != previous && !current.isEmpty
    }
}
