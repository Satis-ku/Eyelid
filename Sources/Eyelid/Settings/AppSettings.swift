import CoreGraphics
import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let openDelay = "openDelay"
        static let hapticsEnabled = "hapticsEnabled"
        static let showsLiveActivity = "showsLiveActivity"
        static let showsTrackTitle = "showsTrackTitle"
        static let equalizerFollowsAudio = "equalizerFollowsAudio"
        static let isLiveActivityHidden = "isLiveActivityHidden"
        static let showsClockWhenIdle = "showsClockWhenIdle"
        static let showsDateInOpenNotch = "showsDateInOpenNotch"
        static let liveActivityShortcutEnabled = "liveActivityShortcutEnabled"
        static let liveActivityHotKey = "liveActivityHotKey"
        static let batteryActivityEnabled = "batteryActivityEnabled"
        static let outputActivityEnabled = "outputActivityEnabled"
        static let replacesSystemHUD = "replacesSystemHUD"
        static let hudLevelStyle = "hudLevelStyle"
        static let deviceIcons = "deviceIcons"
        static let displayID = "displayID"
        static let notchOnAllDisplays = "notchOnAllDisplays"
        static let shelfEnabled = "shelfEnabled"
        static let shelfRemovesDraggedFiles = "shelfRemovesDraggedFiles"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardHotKey = "clipboardHotKey"
        static let clipboardPastesAfterChoosing = "clipboardPastesAfterChoosing"
    }

    /// Delays offered in Settings, in seconds.
    static let openDelayOptions: [TimeInterval] = [0, 0.1, 0.25, 0.5, 1]

    /// How long the pointer has to rest on the notch before it opens.
    var openDelay: TimeInterval {
        didSet { defaults.set(openDelay, forKey: Key.openDelay) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    /// Whether artwork and an equalizer appear next to the closed notch while something plays.
    var showsLiveActivity: Bool {
        didSet { defaults.set(showsLiveActivity, forKey: Key.showsLiveActivity) }
    }

    /// Whether the live activity and track titles are hidden for now, with the shortcut or the menu, so the notch
    /// takes no more room in the menu bar than the camera. Volume, battery and output changes still show.
    var isLiveActivityHidden: Bool {
        didSet { defaults.set(isLiveActivityHidden, forKey: Key.isLiveActivityHidden) }
    }

    /// Whether the time and the battery show beside the closed notch while nothing plays, so it isn't bare. Off by
    /// default.
    var showsClockWhenIdle: Bool {
        didSet { defaults.set(showsClockWhenIdle, forKey: Key.showsClockWhenIdle) }
    }

    /// Whether the open notch shows the date and time next to the battery.
    var showsDateInOpenNotch: Bool {
        didSet { defaults.set(showsDateInOpenNotch, forKey: Key.showsDateInOpenNotch) }
    }

    /// Whether `liveActivityHotKey` hides and shows the live activity.
    var liveActivityShortcutEnabled: Bool {
        didSet { defaults.set(liveActivityShortcutEnabled, forKey: Key.liveActivityShortcutEnabled) }
    }

    /// The shortcut that hides and shows the live activity.
    var liveActivityHotKey: HotKey {
        didSet { Self.store(liveActivityHotKey, as: Key.liveActivityHotKey, in: defaults) }
    }

    /// Whether the equalizer next to the notch moves with the sound that's playing, rather than on its own. Off by
    /// default, since macOS asks to allow Eyelid to record system audio for it.
    var equalizerFollowsAudio: Bool {
        didSet { defaults.set(equalizerFollowsAudio, forKey: Key.equalizerFollowsAudio) }
    }

    /// Whether the title of what starts playing shows for a moment under the closed notch, in the colors of its
    /// artwork.
    var showsTrackTitle: Bool {
        didSet { defaults.set(showsTrackTitle, forKey: Key.showsTrackTitle) }
    }

    /// Whether plugging in, unplugging and a low battery briefly show the charge next to the notch.
    var batteryActivityEnabled: Bool {
        didSet { defaults.set(batteryActivityEnabled, forKey: Key.batteryActivityEnabled) }
    }

    /// Whether a switch of the sound output briefly shows the new one next to the notch: AirPods and Beats with their
    /// charge and the earbuds in use, others with their volume.
    var outputActivityEnabled: Bool {
        didSet { defaults.set(outputActivityEnabled, forKey: Key.outputActivityEnabled) }
    }

    /// Whether Eyelid handles the volume and brightness keys and shows the change next to the notch
    /// instead of the system HUD. Off by default, since it needs Accessibility access.
    var replacesSystemHUD: Bool {
        didSet { defaults.set(replacesSystemHUD, forKey: Key.replacesSystemHUD) }
    }

    var hudLevelStyle: LevelStyle {
        didSet { defaults.set(hudLevelStyle.rawValue, forKey: Key.hudLevelStyle) }
    }

    /// Icons picked for output devices, by CoreAudio device UID. Devices without one get `DeviceIcon.automatic`.
    var deviceIcons: [String: DeviceIcon] {
        didSet { defaults.set(deviceIcons.mapValues(\.rawValue), forKey: Key.deviceIcons) }
    }

    /// The display that shows the notch, or nil to pick one automatically.
    var displayID: CGDirectDisplayID? {
        didSet {
            if let displayID {
                defaults.set(Int(displayID), forKey: Key.displayID)
            } else {
                defaults.removeObject(forKey: Key.displayID)
            }
        }
    }

    /// Whether files dropped on the notch are kept on a shelf in the open notch.
    var shelfEnabled: Bool {
        didSet { defaults.set(shelfEnabled, forKey: Key.shelfEnabled) }
    }

    /// Whether a file leaves the shelf once it is dragged out and dropped somewhere.
    var shelfRemovesDraggedFiles: Bool {
        didSet { defaults.set(shelfRemovesDraggedFiles, forKey: Key.shelfRemovesDraggedFiles) }
    }

    /// Whether Eyelid keeps a history of what's copied. Off by default: it sees everything you copy, and
    /// macOS asks before letting it.
    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }

    /// The shortcut that opens the clipboard history.
    var clipboardHotKey: HotKey {
        didSet { Self.store(clipboardHotKey, as: Key.clipboardHotKey, in: defaults) }
    }

    /// Whether choosing a copy also pastes it into the app in front. Needs Accessibility access to press ⌘V.
    var clipboardPastesAfterChoosing: Bool {
        didSet { defaults.set(clipboardPastesAfterChoosing, forKey: Key.clipboardPastesAfterChoosing) }
    }

    /// Whether every display shows a notch, rather than only `displayID` or the automatic choice.
    var notchOnAllDisplays: Bool {
        didSet { defaults.set(notchOnAllDisplays, forKey: Key.notchOnAllDisplays) }
    }

    private let defaults: any SettingsStore

    init(defaults: any SettingsStore = UserDefaults.standard) {
        self.defaults = defaults
        openDelay = defaults.object(forKey: Key.openDelay) as? TimeInterval ?? 0
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        showsLiveActivity = defaults.object(forKey: Key.showsLiveActivity) as? Bool ?? true
        showsTrackTitle = defaults.object(forKey: Key.showsTrackTitle) as? Bool ?? true
        equalizerFollowsAudio = defaults.object(forKey: Key.equalizerFollowsAudio) as? Bool ?? false
        batteryActivityEnabled = defaults.object(forKey: Key.batteryActivityEnabled) as? Bool ?? true
        outputActivityEnabled = defaults.object(forKey: Key.outputActivityEnabled) as? Bool ?? true
        replacesSystemHUD = defaults.object(forKey: Key.replacesSystemHUD) as? Bool ?? false
        hudLevelStyle = (defaults.object(forKey: Key.hudLevelStyle) as? String).flatMap(LevelStyle.init(rawValue:)) ?? .bar
        deviceIcons = (defaults.object(forKey: Key.deviceIcons) as? [String: String] ?? [:])
            .compactMapValues(DeviceIcon.init(rawValue:))
        displayID = (defaults.object(forKey: Key.displayID) as? Int).map { CGDirectDisplayID($0) }
        notchOnAllDisplays = defaults.object(forKey: Key.notchOnAllDisplays) as? Bool ?? false
        shelfEnabled = defaults.object(forKey: Key.shelfEnabled) as? Bool ?? true
        shelfRemovesDraggedFiles = defaults.object(forKey: Key.shelfRemovesDraggedFiles) as? Bool ?? true
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        clipboardPastesAfterChoosing = defaults.object(forKey: Key.clipboardPastesAfterChoosing) as? Bool ?? false
        clipboardHotKey = Self.hotKey(Key.clipboardHotKey, in: defaults) ?? .clipboardDefault
        isLiveActivityHidden = defaults.object(forKey: Key.isLiveActivityHidden) as? Bool ?? false
        showsClockWhenIdle = defaults.object(forKey: Key.showsClockWhenIdle) as? Bool ?? false
        showsDateInOpenNotch = defaults.object(forKey: Key.showsDateInOpenNotch) as? Bool ?? true
        liveActivityShortcutEnabled = defaults.object(forKey: Key.liveActivityShortcutEnabled) as? Bool ?? true
        liveActivityHotKey = Self.hotKey(Key.liveActivityHotKey, in: defaults) ?? .liveActivityDefault
    }

    private static func store(_ hotKey: HotKey, as key: String, in defaults: any SettingsStore) {
        defaults.set(["keyCode": Int(hotKey.keyCode), "modifiers": Int(hotKey.modifiers)], forKey: key)
    }

    private static func hotKey(_ key: String, in defaults: any SettingsStore) -> HotKey? {
        guard let stored = defaults.object(forKey: key) as? [String: Int],
              let keyCode = stored["keyCode"], let modifiers = stored["modifiers"]
        else { return nil }
        return HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
}

extension AppSettings {
    /// The display setting as one choice, as Settings offers it.
    var notchDisplays: NotchDisplays {
        get {
            if notchOnAllDisplays { return .all }
            return displayID.map(NotchDisplays.display) ?? .automatic
        }
        set {
            notchOnAllDisplays = newValue == .all
            if case .display(let id) = newValue {
                displayID = id
            } else if newValue == .automatic {
                displayID = nil
            }
        }
    }

    func icon(for device: OutputDevice) -> DeviceIcon {
        deviceIcons[device.id] ?? .automatic(for: device)
    }
}

/// Where `AppSettings` keeps its values: `UserDefaults` in the app, memory in tests.
/// Any `UserDefaults` domain that gets written to stays on disk, even after `removePersistentDomain`.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}
