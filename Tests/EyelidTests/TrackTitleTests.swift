import CoreGraphics
import Foundation
import Testing
@testable import Eyelid

@Suite("Track title")
struct TrackTitleTests {
    private func track(_ title: String = "Song", artist: String = "Artist", album: String = "", isPlaying: Bool = true)
        -> NowPlayingTrack {
        NowPlayingTrack(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            playbackRate: 1,
            duration: 200,
            elapsedTime: 0,
            timestamp: nil,
            artwork: nil,
            appName: nil,
            appIcon: nil
        )
    }

    @Test func newTrackIsAStart() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now

        do { let isStart = starts.isStart(track("One"), at: now); #expect(isStart) }
        starts.didReport(track("One"))
        do { let isStart = starts.isStart(track("One"), at: now); #expect(!isStart) }
        do { let isStart = starts.isStart(track("Two"), at: now); #expect(isStart) }
        do { let isStart = starts.isStart(track("One", artist: "Other"), at: now); #expect(isStart) }
        do { let isStart = starts.isStart(track("One", album: "Other"), at: now); #expect(isStart) }
    }

    @Test func playingOnIsNotAStart() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now
        starts.didReport(track())
        var later = track()
        later.elapsedTime = 42

        do { let isStart = starts.isStart(later, at: now + .seconds(30)); #expect(!isStart) }
    }

    @Test func seekIsNotAStartButARealPauseIs() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now
        starts.didReport(track())

        // Seeking pauses for a moment.
        do { let isStart = starts.isStart(track(isPlaying: false), at: now); #expect(!isStart) }
        do { let isStart = starts.isStart(track(), at: now + .milliseconds(80)); #expect(!isStart) }
        // A real pause.
        do { let isStart = starts.isStart(track(isPlaying: false), at: now + .seconds(1)); #expect(!isStart) }
        do { let isStart = starts.isStart(track(), at: now + .seconds(1) + PlaybackStarts.shortPause); #expect(isStart) }
    }

    /// Players resend a paused track now and then: the pause still counts from when it began.
    @Test func aPauseCountsFromItsStart() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now
        starts.didReport(track())

        _ = starts.isStart(track(isPlaying: false), at: now)
        _ = starts.isStart(track(isPlaying: false), at: now + .seconds(9))

        let isStart = starts.isStart(track(), at: now + PlaybackStarts.shortPause)
        #expect(isStart)
    }

    /// A muted preview plays and pauses as the pointer comes and goes, and is never heard, so never reported. Opening
    /// that video is still a start.
    @Test func unreportedTrackStaysAStartThroughShortPauses() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now

        do { let isStart = starts.isStart(track("Preview"), at: now); #expect(isStart) }
        do { let isStart = starts.isStart(track("Preview", isPlaying: false), at: now + .seconds(1)); #expect(!isStart) }
        do { let isStart = starts.isStart(track("Preview"), at: now + .seconds(2)); #expect(isStart) }
    }

    @Test func pausesAndUntitledMediaAreNotStarts() {
        var starts = PlaybackStarts()
        let now = ContinuousClock.now

        do { let isStart = starts.isStart(track(isPlaying: false), at: now); #expect(!isStart) }
        do { let isStart = starts.isStart(track(""), at: now); #expect(!isStart) }
        do { let isStart = starts.isStart(nil, at: now); #expect(!isStart) }
    }

    @Test func measuresEachCharacterInTheLine() {
        let line = TitleLine(title: "Йод 🎧", artist: "Би-2")

        #expect(line.characters.map(\.text).joined() == "Йод 🎧" + TrackTitle.separator + "Би-2")
        // The emoji is one character, not two halves.
        #expect(line.characters.contains { $0.text == "🎧" })
        #expect(zip(line.characters, line.characters.dropFirst()).allSatisfy { $0.offset < $1.offset })
        #expect(line.characters.filter(\.isDetail).map(\.text).joined() == TrackTitle.separator + "Би-2")
        #expect(abs((line.characters.last.map { $0.offset + $0.width } ?? 0) - line.width) < 1)
    }

    @Test func artistMakesTheLineLonger() {
        #expect(TitleLine(title: "Song", artist: "Artist").width > TitleLine(title: "Song", artist: "").width)
    }

    @Test func textComesInAtTheRightAndLeavesAtTheLeft() {
        let width: CGFloat = 120
        let length: CGFloat = 300
        let duration = TrackTitle.duration(textWidth: width, pathLength: length)

        #expect(TrackTitle.textStart(after: 0, textWidth: width, pathLength: length) == length - TrackTitle.lead)
        #expect(TrackTitle.textStart(after: 1, textWidth: width, pathLength: length) == length - TrackTitle.lead - TrackTitle.speed)
        // Gone past the left end when it's over.
        #expect(abs(TrackTitle.textStart(after: duration, textWidth: width, pathLength: length) + width) < 0.001)
    }

    @Test func longTitlesRunFasterToFitInTime() {
        let width: CGFloat = 900

        #expect(TrackTitle.speed(textWidth: width, pathLength: 300) > TrackTitle.speed)
        #expect(abs(TrackTitle.duration(textWidth: width, pathLength: 300) - TrackTitle.maxDuration) < 0.001)
    }

    @Test func curveRunsAlongTheLidFromCornerToCorner() throws {
        let curve = LidCurve(width: 269, depth: 30, inset: 8)

        let left = try #require(curve.point(at: 0))
        let middle = try #require(curve.point(at: curve.length / 2))
        let right = try #require(curve.point(at: curve.length))

        #expect(curve.length > 269)
        #expect(abs(left.position.x) < 0.001 && abs(left.position.y + 8) < 0.001)
        #expect(abs(middle.position.x - 134.5) < 0.5)
        #expect(abs(middle.position.y - (30 - 8)) < 0.5)
        #expect(abs(middle.angle) < 0.05)
        #expect(abs(right.position.x - 269) < 0.001)
        // Down into the lid on the left, back up on the right.
        #expect(left.angle > 0.5 && right.angle < -0.5)
        #expect(curve.point(at: -1) == nil && curve.point(at: curve.length + 1) == nil)
    }
}

@Suite("Artwork color")
struct ArtworkColorTests {
    /// An image filled with one color, or with two side by side.
    private func image(_ colors: [(red: Double, green: Double, blue: Double)], width: Int = 64) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let stripe = CGFloat(width) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * stripe, y: 0, width: stripe, height: 64))
        }
        return try #require(context.makeImage())
    }

    @Test func findsTheColorOfPlainArtwork() throws {
        let color = try #require(ArtworkColor.accent(of: image([(0.85, 0.1, 0.1)])))

        #expect(abs(color.red - 0.85) < 0.02)
        #expect(color.green < 0.15 && color.blue < 0.15)
    }

    @Test func prefersTheVividColorOverGray() throws {
        // Three quarters gray, one quarter blue.
        let color = try #require(ArtworkColor.accent(of: image([(0.5, 0.5, 0.5), (0.5, 0.5, 0.5), (0.5, 0.5, 0.5), (0.1, 0.3, 0.9)])))

        #expect(color.blue > 0.8)
        #expect(color.red < 0.2)
    }

    @Test func blackAndWhiteArtworkHasNoColor() throws {
        #expect(ArtworkColor.accent(of: try image([(0, 0, 0), (1, 1, 1), (0.4, 0.4, 0.4)])) == nil)
    }

    @Test(arguments: [0.0, 0.08, 0.17, 0.33, 0.5, 0.62, 0.67, 0.75, 0.83, 0.95])
    func everyHueStaysReadableOnBlack(hue: Double) {
        let deep = ArtworkColor(hsb: .init(hue: hue, saturation: 1, brightness: 0.4))

        let legible = deep.legibleOnBlack

        #expect(legible.luminance >= ArtworkColor.minLuminance)
        // Still the same hue, not washed out to white.
        #expect(abs(legible.hsb.hue - hue) < 0.02 || abs(legible.hsb.hue - hue) > 0.98)
        #expect(legible.hsb.saturation > 0.2)
    }

    @Test func convertsBetweenRGBAndHSB() {
        let color = ArtworkColor(red: 0.2, green: 0.6, blue: 0.4)

        let back = ArtworkColor(hsb: color.hsb)

        #expect(abs(back.red - 0.2) < 0.001 && abs(back.green - 0.6) < 0.001 && abs(back.blue - 0.4) < 0.001)
    }
}
