import Foundation
import Testing
@testable import Eyelid

@Suite("Playback time")
struct NowPlayingTrackTests {
    private let reportedAt = Date(timeIntervalSince1970: 1_000_000)

    private func track(
        isPlaying: Bool,
        elapsedTime: TimeInterval? = 30,
        duration: TimeInterval? = 200,
        playbackRate: Double = 1,
        artist: String = "",
        appName: String? = nil
    ) -> NowPlayingTrack {
        NowPlayingTrack(
            title: "Track",
            artist: artist,
            album: "",
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            duration: duration,
            elapsedTime: elapsedTime,
            timestamp: reportedAt,
            artwork: nil,
            appName: appName,
            appIcon: nil
        )
    }

    @Test func pausedTrackKeepsItsPosition() {
        let track = track(isPlaying: false)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(60)) == 30)
    }

    @Test func playingTrackAdvancesWithTime() {
        let track = track(isPlaying: true)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(10)) == 40)
    }

    @Test func playbackRateScalesTheAdvance() {
        let track = track(isPlaying: true, playbackRate: 2)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(10)) == 50)
    }

    @Test func stopsAtTheEnd() {
        let track = track(isPlaying: true)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(1_000)) == 200)
    }

    @Test func neverGoesBelowZero() {
        // The clock can be slightly behind the timestamp the player reported.
        let track = track(isPlaying: true)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(-100)) == 0)
    }

    @Test func liveStreamsWithoutADurationKeepCounting() {
        let track = track(isPlaying: true, duration: nil)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(1_000)) == 1_030)
    }

    @Test func unknownPositionStaysUnknown() {
        let track = track(isPlaying: true, elapsedTime: nil)

        #expect(track.elapsedTime(at: reportedAt.addingTimeInterval(10)) == nil)
    }

    @Test func subtitleIsTheArtist() {
        #expect(track(isPlaying: true, artist: "Kwoon", appName: "Music").subtitle == "Kwoon")
    }

    @Test func subtitleFallsBackToTheAppName() {
        #expect(track(isPlaying: true, artist: "", appName: "Firefox").subtitle == "Firefox")
        #expect(track(isPlaying: true, artist: "", appName: nil).subtitle == "")
    }

    @MainActor
    @Test(arguments: zip(
        [0, 5.9, 65, 599, 3_600, 3_723, -3] as [TimeInterval],
        ["0:00", "0:05", "1:05", "9:59", "1:00:00", "1:02:03", "0:00"]
    ))
    func formatsTimes(seconds: TimeInterval, expected: String) {
        #expect(PlaybackProgressView.format(seconds) == expected)
    }
}

@MainActor
@Suite("Seeking")
struct SeekingTests {
    private let reportedAt = Date(timeIntervalSince1970: 1_000_000)

    /// Playing, 30 s in as of `reportedAt`, 200 s long.
    private func track(reportedAt: Date? = nil, isPlaying: Bool = true) -> NowPlayingTrack {
        NowPlayingTrack(
            title: "Track",
            artist: "",
            album: "",
            isPlaying: isPlaying,
            playbackRate: 1,
            duration: 200,
            elapsedTime: 30,
            timestamp: reportedAt ?? self.reportedAt,
            artwork: nil,
            appName: nil,
            appIcon: nil
        )
    }

    private func position(
        after seconds: TimeInterval,
        of track: NowPlayingTrack,
        dragged: TimeInterval? = nil,
        sought: PlaybackProgressView.Seek? = nil
    ) -> TimeInterval {
        PlaybackProgressView.position(at: reportedAt.addingTimeInterval(seconds), of: track, dragged: dragged, sought: sought)
    }

    @Test func theBarFollowsADrag() {
        #expect(position(after: 1, of: track(), dragged: 150) == 150)
    }

    /// The player takes a moment to report a seek, and the bar doesn't jump back meanwhile.
    @Test func aSeekShowsUntilThePlayerReportsIt() {
        let sought = PlaybackProgressView.Seek(position: 120, at: reportedAt.addingTimeInterval(10), title: "Track", artist: "")

        #expect(position(after: 10.5, of: track(), sought: sought) == 120.5)
        #expect(position(after: 10.5, of: track(isPlaying: false), sought: sought) == 120)

        // The player reports where it is now, and the bar follows it again.
        var reported = track(reportedAt: reportedAt.addingTimeInterval(10.4))
        reported.elapsedTime = 120
        #expect(abs(position(after: 10.5, of: reported, sought: sought) - 120.1) < 0.001)
    }

    /// While seeking, players send a fresh update or two still at the old position: the bar doesn't go back to it.
    @Test func anUpdateFromBeforeTheSeekDoesntPullTheBarBack() {
        let sought = PlaybackProgressView.Seek(position: 120, at: reportedAt.addingTimeInterval(10), title: "Track", artist: "")
        var stale = track(reportedAt: reportedAt.addingTimeInterval(10.2))
        stale.elapsedTime = 40

        #expect(position(after: 10.5, of: stale, sought: sought) == 120.5)
    }

    /// A player that can't seek reports nothing new: the bar goes back to where it really is.
    @Test func aSeekThePlayerIgnoresIsForgotten() {
        let sought = PlaybackProgressView.Seek(position: 120, at: reportedAt.addingTimeInterval(10), title: "Track", artist: "")

        let later = 10 + PlaybackProgressView.seekGrace
        #expect(position(after: later, of: track(), sought: sought) == 30 + later)
    }

    /// Skipping to the next track right after a seek starts it from its own beginning, not the seek's position.
    @Test func aSeekBelongsToItsTrack() {
        let sought = PlaybackProgressView.Seek(position: 120, at: reportedAt.addingTimeInterval(10), title: "Track", artist: "")
        var next = track(reportedAt: reportedAt.addingTimeInterval(10.5))
        next.title = "Next Track"
        next.elapsedTime = 0

        #expect(position(after: 11, of: next, sought: sought) == 0.5)
    }

    @Test func theAdapterTakesWholeMicroseconds() {
        #expect(MediaRemoteAdapter.micros(83.25) == 83_250_000)
        #expect(MediaRemoteAdapter.micros(-4) == 0)
    }
}
