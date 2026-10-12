import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Eyelid

/// macOS reports a new track a moment before its artwork. The notch shouldn't blink to the placeholder in between,
/// and the title should show in the new artwork's colors.
@MainActor
@Suite("Artwork on its way", .timeLimit(.minutes(1)))
struct NowPlayingArtworkWaitTests {
    private final class Starts {
        var count = 0
    }

    private func png(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Each title has its own artist and length unless they're given, as tracks usually do.
    private func snapshot(
        _ title: String,
        artist: String? = nil,
        album: String = "",
        duration: Double? = nil,
        elapsed: Double = 0,
        playing: Bool = true,
        artwork: Data? = nil
    ) throws -> NowPlayingSnapshot {
        let artist = artist ?? "Artist of \(title)"
        let micros = (duration ?? Double(100 + title.count)) * 1_000_000
        let json = #"{"title":"\#(title)","artist":"\#(artist)","album":"\#(album)","playing":\#(playing),"durationMicros":\#(micros),"elapsedTimeMicros":\#(elapsed * 1_000_000)}"#
        let payload = try JSONDecoder().decode(AdapterStreamMessage.Payload.self, from: Data(json.utf8))
        var snapshot = try #require(NowPlayingSnapshot(payload: payload))
        snapshot.artworkData = artwork
        snapshot.artwork = artwork.flatMap(Artwork.init(data:))
        return snapshot
    }

    private func service(_ starts: Starts) -> NowPlayingService {
        // Whether players are heard can't be told here, so every start is reported.
        let service = NowPlayingService(artworkGrace: 0.06, earlyTitleWait: 0.06, isAudible: { _ in nil })
        service.onPlaybackStart = {
            starts.count += 1
        }
        return service
    }

    /// What Yandex Music sends as the track changes: the new title with the rest of the previous track, twice, then
    /// its artist, album and length, then its artwork.
    @Test func titleAndArtistChangeTogether() throws {
        let starts = Starts()
        let service = service(starts)
        let red = try png(red: 0.9, green: 0.1, blue: 0.1)
        let blue = try png(red: 0.1, green: 0.2, blue: 0.9)
        service.apply(try snapshot("One", artist: "Би-2", album: "Иномарки", duration: 204, elapsed: 3, artwork: red))

        service.apply(try snapshot("Two", artist: "Би-2", album: "Иномарки", duration: 204, elapsed: 3))
        service.apply(try snapshot("Two", artist: "Би-2", album: "Иномарки", duration: 204, elapsed: 3, artwork: red))
        // Still the previous track: the new title doesn't show with the old artist. The lid opens already.
        #expect(service.track?.title == "One")
        #expect(starts.count == 2)

        service.apply(try snapshot("Two", artist: "Любэ", album: "Том 2", duration: 110, elapsed: 0))
        #expect(service.track?.title == "Two")
        #expect(service.track?.artist == "Любэ")
        #expect(starts.count == 2)
        // The previous colors stay until the new artwork comes.
        #expect((service.track?.artworkColor?.red ?? 0) > 0.8)

        service.apply(try snapshot("Two", artist: "Любэ", album: "Том 2", duration: 110, elapsed: 0, artwork: blue))
        #expect((service.track?.artworkColor?.blue ?? 0) > 0.8)
    }

    @Test func earlyTitleShowsOnItsOwnIfTheRestNeverComes() async throws {
        let starts = Starts()
        let service = service(starts)
        service.apply(try snapshot("One", artist: "Band", album: "Album", duration: 200, elapsed: 0))

        service.apply(try snapshot("Two", artist: "Band", album: "Album", duration: 200, elapsed: 0))
        await service.earlyTitleTask?.value

        #expect(service.track?.title == "Two")
        #expect(starts.count == 2)
    }

    @Test func tellsEarlyTitlesFromNewTracks() throws {
        let service = service(Starts())
        service.apply(try snapshot("One", artist: "Band", album: "Album", duration: 200, elapsed: 42))
        let track = try #require(service.track)

        #expect(NowPlayingService.isEarlyTitle(try snapshot("Two", artist: "Band", album: "Album", duration: 200, elapsed: 42), after: track))
        // The next track of the album starts from the beginning, and is rarely just as long.
        #expect(!NowPlayingService.isEarlyTitle(try snapshot("Two", artist: "Band", album: "Album", duration: 180, elapsed: 0), after: track))
        #expect(!NowPlayingService.isEarlyTitle(try snapshot("Two", artist: "Other", album: "Album", duration: 200, elapsed: 42), after: track))
        #expect(!NowPlayingService.isEarlyTitle(try snapshot("One", artist: "Band", album: "Album", duration: 200, elapsed: 42), after: track))
    }

    /// What Yandex Music sends as the track changes: no artwork, the previous track's, none again, then its own.
    @Test func keepsThePreviousArtworkUntilTheNewTracksOwnComes() throws {
        let starts = Starts()
        let service = service(starts)
        let red = try png(red: 0.9, green: 0.1, blue: 0.1)
        let blue = try png(red: 0.1, green: 0.2, blue: 0.9)
        service.apply(try snapshot("One", artwork: red))
        #expect(!service.isAwaitingArtwork)

        service.apply(try snapshot("Two"))
        // The notch reacts right away, and the title waits for the artwork.
        #expect(starts.count == 2)
        #expect(service.isAwaitingArtwork)
        for update in [try snapshot("Two", artwork: red), try snapshot("Two")] {
            service.apply(update)
            #expect(service.isAwaitingArtwork)
            #expect((service.track?.artworkColor?.red ?? 0) > 0.8)
        }

        service.apply(try snapshot("Two", artwork: blue))

        #expect(!service.isAwaitingArtwork)
        #expect((service.track?.artworkColor?.blue ?? 0) > 0.8)
        #expect(starts.count == 2)
    }

    @Test func trackWithoutArtworkShowsOnceTheWaitIsOver() async throws {
        let starts = Starts()
        let service = service(starts)
        service.apply(try snapshot("One", artwork: try png(red: 0.9, green: 0.1, blue: 0.1)))

        service.apply(try snapshot("Two"))
        await service.artworkWait?.value

        #expect(!service.isAwaitingArtwork)
        #expect(service.track?.title == "Two")
        #expect(service.track?.artwork == nil)
        #expect(service.track?.artworkColor == nil)
    }

    @Test func nextTrackOfTheSameAlbumKeepsItsArtwork() async throws {
        let starts = Starts()
        let service = service(starts)
        let cover = try png(red: 0.2, green: 0.8, blue: 0.3)
        service.apply(try snapshot("One", artwork: cover))

        service.apply(try snapshot("Two"))
        service.apply(try snapshot("Two", artwork: cover))
        await service.artworkWait?.value

        #expect(!service.isAwaitingArtwork)
        #expect(service.track?.artwork != nil)
        #expect((service.track?.artworkColor?.green ?? 0) > 0.7)
    }

    /// Seeking in YouTube pauses for a moment, then plays on: not a start.
    @Test func playingOnAfterAMomentIsNotAStart() throws {
        let starts = Starts()
        let service = service(starts)
        let cover = try png(red: 0.9, green: 0.6, blue: 0.1)

        service.apply(try snapshot("One", artwork: cover))
        service.apply(try snapshot("One", playing: false, artwork: cover))
        service.apply(try snapshot("One", artwork: cover))

        #expect(starts.count == 1)
        #expect(!service.isAwaitingArtwork)
    }

    @Test func updatesWithoutArtworkLeaveTheTrackAsItIs() throws {
        let starts = Starts()
        let service = service(starts)
        service.apply(try snapshot("One", artwork: try png(red: 0.9, green: 0.1, blue: 0.1)))

        service.apply(try snapshot("One"))

        #expect(service.track?.artwork != nil)
    }

    /// YouTube plays muted previews as the pointer passes over them, and reports each as playing.
    @Test func silentPlaybackIsNotAStartUntilItIsHeard() async throws {
        let starts = Starts()
        final class Sound { var isOn = false }
        let sound = Sound()
        let service = NowPlayingService(artworkGrace: 0.06, earlyTitleWait: 0.06, isAudible: { _ in sound.isOn })
        service.onPlaybackStart = { starts.count += 1 }

        service.apply(try snapshot("Preview"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(starts.count == 0)

        #expect(service.isSilent)

        // The pointer leaves and comes back, then the video opens: the same item, now heard.
        service.apply(try snapshot("Preview", playing: false))
        service.apply(try snapshot("Preview"))
        let heard = try #require(service.audibleTask)
        sound.isOn = true
        await heard.value
        #expect(starts.count == 1)
        #expect(!service.isSilent)
    }

    /// A muted preview that stops is no longer waited on, and isn't silent anymore.
    @Test func silentPlaybackThatStopsIsForgotten() throws {
        let service = NowPlayingService(artworkGrace: 0.06, earlyTitleWait: 0.06, isAudible: { _ in false })

        service.apply(try snapshot("Preview"))
        #expect(service.audibleTask != nil)
        #expect(service.isSilent)

        service.apply(try snapshot("Preview", playing: false))
        #expect(service.audibleTask == nil)
        #expect(service.isSilent == false)
    }
}
