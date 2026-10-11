import Foundation

/// The pages of System Settings that Eyelid sends the user to.
enum SystemSettingsPage {
    /// Privacy & Security → Paste from Other Apps.
    static let pasteFromOtherApps = page("com.apple.preference.security?Privacy_Pasteboard")
    /// Privacy & Security → Accessibility.
    static let accessibility = page("com.apple.preference.security?Privacy_Accessibility")
    /// General → Language & Region, where Translation Languages are downloaded.
    static let languageAndRegion = page("com.apple.Localization-Settings.extension")
    static let sound = page("com.apple.Sound-Settings.extension")

    private static func page(_ path: String) -> URL {
        // These are constant strings, which always make a URL.
        URL(string: "x-apple.systempreferences:" + path)!
    }
}
