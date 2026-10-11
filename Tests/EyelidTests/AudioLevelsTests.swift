import Testing
@testable import Eyelid

@MainActor
@Suite("Equalizer listening")
struct AudioLevelsTests {
    private let settings = AppSettings(defaults: InMemorySettingsStore())

    /// While nobody can see the equalizer, Eyelid doesn't listen for it, so macOS shows no recording indicator.
    @Test func theEqualizerIsSeenOnlyWithTheLiveActivityShowing() {
        let levels = AudioLevels(settings: settings, nowPlaying: NowPlayingService())
        #expect(levels.isEqualizerVisible)

        settings.isLiveActivityHidden = true
        #expect(!levels.isEqualizerVisible)

        settings.isLiveActivityHidden = false
        settings.showsLiveActivity = false
        #expect(!levels.isEqualizerVisible)
    }
}
