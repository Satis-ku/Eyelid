import Foundation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "MediaRemoteAdapter")

/// Talks to [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter).
///
/// Since macOS 15.4, MediaRemote (the private framework behind the Now Playing widget) only answers
/// entitled Apple processes. The adapter loads a small framework into Apple's own `/usr/bin/perl`,
/// which is still entitled, and prints now playing updates as JSON lines.
struct MediaRemoteAdapter: Sendable {
    /// MediaRemote command IDs (`MRCommand`) accepted by `send`.
    enum Command: Int, Sendable {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    let script: URL
    let framework: URL

    /// Finds the adapter inside the app bundle, or in the repository when started with `swift run`.
    static func locate() -> MediaRemoteAdapter? {
        var candidates: [MediaRemoteAdapter] = []

        if let resources = Bundle.main.resourceURL, let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(MediaRemoteAdapter(
                script: resources.appending(path: "mediaremote-adapter.pl"),
                framework: frameworks.appending(path: "MediaRemoteAdapter.framework")
            ))
        }

        #if DEBUG
        // `swift run` from the repository root, once `make app` has built the framework. Release builds
        // never run code from the working directory, which anyone launching the app could pick.
        let root = URL(filePath: FileManager.default.currentDirectoryPath)
        candidates.append(MediaRemoteAdapter(
            script: root.appending(path: "Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"),
            framework: root.appending(path: ".build/adapter/MediaRemoteAdapter.framework")
        ))
        #endif

        let fileManager = FileManager.default
        return candidates.first {
            fileManager.fileExists(atPath: $0.script.path) && fileManager.fileExists(atPath: $0.framework.path)
        }
    }

    func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        // Perl runs extra code named in PERL5OPT and PERL5LIB, and macOS treats Eyelid as responsible for
        // its child processes. So perl doesn't inherit Eyelid's environment, only what it needs.
        process.environment = Self.environment
        return process
    }

    static let environment = ["PATH": "/usr/bin:/bin"]

    /// Sends a command without waiting for the adapter to finish, which takes a moment as perl starts.
    func send(_ command: Command) {
        run(["send", String(command.rawValue)])
    }

    /// Moves playback to `position`, in seconds from the start. Players that can't seek ignore it.
    func seek(to position: TimeInterval) {
        run(["seek", String(Self.micros(position))])
    }

    /// The position as the adapter takes it: whole microseconds, and none before the start.
    static func micros(_ position: TimeInterval) -> Int64 {
        Int64((max(position, 0) * 1_000_000).rounded())
    }

    private func run(_ arguments: [String]) {
        let process = makeProcess(arguments: arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let name = arguments.joined(separator: " ")
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                logger.error("\(name, privacy: .public) failed: \(process.terminationStatus)")
            }
        }
        do {
            try process.run()
        } catch {
            logger.error("Failed to run \(name, privacy: .public): \(error.localizedDescription)")
        }
    }
}

/// One line of `stream --no-diff --micros` output.
struct AdapterStreamMessage: Decodable {
    struct Payload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let playing: Bool?
        let playbackRate: Double?
        let durationMicros: Double?
        let elapsedTimeMicros: Double?
        let timestampEpochMicros: Double?
        /// Base64-encoded image.
        let artworkData: String?
    }

    let type: String
    let payload: Payload
}
