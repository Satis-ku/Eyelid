import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Eyelid

@Suite("Untrusted artwork")
struct ArtworkTests {
    private func png(width: Int, height: Int) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func scalesArtworkDownToWhatTheNotchShows() throws {
        let artwork = try #require(Artwork(data: try png(width: 1_200, height: 800)))

        #expect(max(artwork.image.width, artwork.image.height) == Artwork.maxPixelSize)
        #expect(artwork.image.width > artwork.image.height)
    }

    @Test func dropsDataThatIsNotAnImage() {
        #expect(Artwork(data: Data("not an image".utf8)) == nil)
        #expect(Artwork(data: Data()) == nil)
    }

    @Test func dropsImagesThatClaimTooManyPixels() {
        #expect(Artwork.isAcceptable(width: 3_000, height: 3_000))
        #expect(!Artwork.isAcceptable(width: 10_000, height: 10_000))
        #expect(!Artwork.isAcceptable(width: 0, height: 500))
        #expect(!Artwork.isAcceptable(width: Int.max, height: 2))
    }

    @Test func dropsOversizedArtworkBeforeDecodingIt() throws {
        let huge = String(repeating: "A", count: Artwork.maxEncodedLength + 4)
        let payload = try JSONDecoder().decode(
            AdapterStreamMessage.Payload.self,
            from: Data(#"{"title":"Song","artworkData":"\#(huge)"}"#.utf8)
        )

        let snapshot = try #require(NowPlayingSnapshot(payload: payload))

        #expect(snapshot.artworkData == nil)
    }
}

@Suite("mediaremote-adapter process")
struct AdapterProcessTests {
    @Test func perlGetsOnlyAPath() {
        // Perl runs code named in variables such as PERL5OPT, so it must not inherit Eyelid's environment.
        let adapter = MediaRemoteAdapter(script: URL(filePath: "/a.pl"), framework: URL(filePath: "/A.framework"))

        #expect(adapter.makeProcess(arguments: ["get"]).environment == ["PATH": "/usr/bin:/bin"])
    }
}
