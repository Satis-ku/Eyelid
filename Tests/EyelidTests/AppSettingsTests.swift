import Foundation
import Testing
@testable import Eyelid

@MainActor
@Suite("Settings")
struct AppSettingsTests {
    @Test func defaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: InMemorySettingsStore())

        #expect(settings.openDelay == 0)
        #expect(settings.hapticsEnabled)
        #expect(settings.showsLiveActivity)
        #expect(settings.showsTrackTitle)
        #expect(!settings.equalizerFollowsAudio)
        #expect(!settings.isLiveActivityHidden)
        #expect(!settings.showsClockWhenIdle)
        #expect(settings.showsDateInOpenNotch)
        #expect(settings.liveActivityShortcutEnabled)
        #expect(settings.liveActivityHotKey == .liveActivityDefault)
        #expect(settings.batteryActivityEnabled)
        #expect(settings.outputActivityEnabled)
        #expect(!settings.replacesSystemHUD)
        #expect(settings.hudLevelStyle == .bar)
        #expect(settings.deviceIcons.isEmpty)
        #expect(settings.displayID == nil)
        #expect(settings.shelfEnabled)
        #expect(settings.shelfRemovesDraggedFiles)
        #expect(!settings.clipboardEnabled)
        #expect(settings.clipboardHotKey == .clipboardDefault)
        #expect(!settings.clipboardPastesAfterChoosing)
    }

    @Test func changesSurviveARelaunch() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(defaults: store)
        settings.openDelay = 0.25
        settings.hapticsEnabled = false
        settings.showsLiveActivity = false
        settings.showsTrackTitle = false
        settings.equalizerFollowsAudio = true
        settings.isLiveActivityHidden = true
        settings.showsClockWhenIdle = true
        settings.showsDateInOpenNotch = false
        settings.liveActivityShortcutEnabled = false
        settings.liveActivityHotKey = HotKey(keyCode: 50, modifiers: 2048)
        settings.batteryActivityEnabled = false
        settings.outputActivityEnabled = false
        settings.replacesSystemHUD = true
        settings.hudLevelStyle = .segments
        settings.deviceIcons = ["headset-uid": .headset]
        settings.displayID = 42
        settings.shelfEnabled = false
        settings.shelfRemovesDraggedFiles = false
        settings.clipboardEnabled = true
        settings.clipboardHotKey = HotKey(keyCode: 9, modifiers: 2048 | 256)
        settings.clipboardPastesAfterChoosing = true

        let relaunched = AppSettings(defaults: store)

        #expect(relaunched.openDelay == 0.25)
        #expect(!relaunched.hapticsEnabled)
        #expect(!relaunched.showsLiveActivity)
        #expect(!relaunched.showsTrackTitle)
        #expect(relaunched.equalizerFollowsAudio)
        #expect(relaunched.isLiveActivityHidden)
        #expect(relaunched.showsClockWhenIdle)
        #expect(!relaunched.showsDateInOpenNotch)
        #expect(!relaunched.liveActivityShortcutEnabled)
        #expect(relaunched.liveActivityHotKey == HotKey(keyCode: 50, modifiers: 2048))
        #expect(!relaunched.batteryActivityEnabled)
        #expect(!relaunched.outputActivityEnabled)
        #expect(relaunched.replacesSystemHUD)
        #expect(relaunched.hudLevelStyle == .segments)
        #expect(relaunched.deviceIcons == ["headset-uid": .headset])
        #expect(relaunched.displayID == 42)
        #expect(!relaunched.shelfEnabled)
        #expect(!relaunched.shelfRemovesDraggedFiles)
        #expect(relaunched.clipboardEnabled)
        #expect(relaunched.clipboardHotKey == HotKey(keyCode: 9, modifiers: 2048 | 256))
        #expect(relaunched.clipboardPastesAfterChoosing)
    }

    @Test func automaticDisplayRemovesTheStoredOne() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(defaults: store)
        settings.displayID = 42

        settings.displayID = nil

        #expect(store.object(forKey: "displayID") == nil)
        #expect(AppSettings(defaults: store).displayID == nil)
    }

    @Test func pickedDeviceIconWinsOverTheAutomaticOne() {
        let settings = AppSettings(defaults: InMemorySettingsStore())
        let headset = OutputDevice(id: "headset-uid", name: "Jabra Evolve", transport: .bluetooth, isHeadphoneJack: false, modelUID: nil)
        #expect(settings.icon(for: headset) == .headphones)

        settings.deviceIcons[headset.id] = .headset

        #expect(settings.icon(for: headset) == .headset)
    }

    @Test func offeredDelaysStartWithInstantly() {
        #expect(AppSettings.openDelayOptions.first == 0)
        #expect(AppSettings.openDelayOptions == AppSettings.openDelayOptions.sorted())
    }
}

/// Keeps settings in memory, so tests neither read nor write the real preferences.
final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}
