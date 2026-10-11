import CoreAudio
import Testing
@testable import Eyelid

/// Stands in for Core Audio's volume notifications.
@MainActor
final class FakeVolumeWatcher: VolumeWatching {
    var onChange: (@MainActor (AudioDeviceID, SystemVolume.State) -> Void)?
    var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

@MainActor
@Suite("Accessibility access for the HUD")
struct HUDAccessTests {
    /// Stands in for System Settings.
    final class Permission {
        var isGranted = false
        var requests = 0
    }

    /// Like the real tap, it only starts with access.
    final class FakeTap: KeyTap {
        let permission: Permission
        var isRunning = false

        init(permission: Permission) {
            self.permission = permission
        }

        func start() -> Bool {
            guard permission.isGranted else { return false }
            isRunning = true
            return true
        }

        func stop() {
            isRunning = false
        }
    }

    private let permission = Permission()
    private let tap: FakeTap
    private let hud: HUDService

    init() {
        let permission = permission
        let tap = FakeTap(permission: permission)
        self.tap = tap
        hud = HUDService(
            settings: AppSettings(defaults: InMemorySettingsStore()),
            access: AccessibilityAccess(
                isGranted: { permission.isGranted },
                request: { permission.requests += 1 }
            ),
            makeTap: { _ in tap },
            volumeWatcher: FakeVolumeWatcher(),
            accessSettleDelay: .milliseconds(10)
        )
    }

    @Test func startsRightAwayWithAccess() {
        permission.isGranted = true

        hud.setEnabled(true)

        #expect(tap.isRunning)
        #expect(permission.requests == 0)
    }

    /// Taking access away while the tap runs can stall input across the Mac, so any change to the list stops it first.
    @Test func stopsAtOnceWhenTheAccessibilityListChanges() async {
        permission.isGranted = true
        hud.setEnabled(true)
        #expect(tap.isRunning)

        permission.isGranted = false
        hud.accessibilityListChanged()

        #expect(!tap.isRunning)
        await hud.accessListTask?.value
        #expect(!tap.isRunning)
    }

    @Test func startsAgainIfAccessStayedAfterTheListChanged() async {
        permission.isGranted = true
        hud.setEnabled(true)

        hud.accessibilityListChanged()

        #expect(!tap.isRunning)
        await hud.accessListTask?.value
        #expect(tap.isRunning)
    }

    @Test func asksOnceAndStartsWhenAccessIsGranted() {
        hud.setEnabled(true)
        hud.setEnabled(false)
        hud.setEnabled(true)
        #expect(!tap.isRunning)
        #expect(permission.requests == 1)

        permission.isGranted = true
        hud.followAccess()

        #expect(tap.isRunning)
    }

    @Test func stopsAsSoonAsAccessIsTakenAway() {
        // A tap that has lost access stalls input across the Mac, so it must not stay.
        permission.isGranted = true
        hud.setEnabled(true)

        permission.isGranted = false
        hud.followAccess()

        #expect(!tap.isRunning)
        #expect(permission.requests == 0)
    }

    @Test func startsAgainWhenAccessComesBack() {
        permission.isGranted = true
        hud.setEnabled(true)
        permission.isGranted = false
        hud.followAccess()

        permission.isGranted = true
        hud.followAccess()

        #expect(tap.isRunning)
    }

    @Test func turningTheHUDOffStopsTheTap() {
        permission.isGranted = true
        hud.setEnabled(true)

        hud.setEnabled(false)

        #expect(!tap.isRunning)
    }
}

@MainActor
@Suite("Volume set without a key")
struct HUDVolumeElsewhereTests {
    private let watcher = FakeVolumeWatcher()
    private let hud: HUDService

    init() {
        hud = HUDService(
            settings: AppSettings(defaults: InMemorySettingsStore()),
            access: AccessibilityAccess(isGranted: { true }, request: {}),
            makeTap: { _ in HUDAccessTests.FakeTap(permission: HUDAccessTests.Permission()) },
            volumeWatcher: watcher
        )
    }

    @Test func watchesOnlyWhileTheHUDIsOn() {
        hud.setEnabled(true)
        #expect(watcher.isRunning)

        hud.setEnabled(false)
        #expect(!watcher.isRunning)
    }

    @Test func showsVolumeFromHeadphonesToo() {
        var events: [HUDEvent] = []
        hud.onEvent = { events.append($0) }
        hud.setEnabled(true)

        watcher.onChange?(AudioDeviceID(kAudioObjectUnknown), SystemVolume.State(level: 0.4, isMuted: false))
        watcher.onChange?(AudioDeviceID(kAudioObjectUnknown), SystemVolume.State(level: 0.4, isMuted: true))

        #expect(events.map(\.kind) == [.volume, .volume])
        #expect(events.map(\.level) == [0.4, 0.4])
        #expect(events.map(\.isMuted) == [false, true])
    }
}
