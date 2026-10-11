import AppKit
import Observation
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "NowPlaying")

/// Keeps `track` in sync with whatever macOS reports as now playing, from any app.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var track: NowPlayingTrack?
    /// Called when something starts playing: a new track, or the same one after a pause. For a track whose title came
    /// early, as soon as the title is in, so the notch can get going while the rest is on its way.
    @ObservationIgnored var onPlaybackStart: (@MainActor () -> Void)?
    /// The start of the track whose title came early is reported already.
    @ObservationIgnored private var startIsReported = false
    /// Tells starts from tracks that play on, pause for a moment or were never heard.
    @ObservationIgnored private var starts = PlaybackStarts()
    /// Whether what plays sends no sound, as a muted YouTube preview: the notch then doesn't show it playing.
    private(set) var isSilent = false
    /// The start waiting to be heard.
    @ObservationIgnored private var pendingStart: PlaybackStarts.Item?
    /// Whether an app is sending any sound, by its bundle identifiers. Nil when that can't be told.
    @ObservationIgnored private let isAudible: @MainActor ([String]) -> Bool?
    /// Waits for what started to be heard, since a muted preview reports playing too.
    @ObservationIgnored private(set) var audibleTask: Task<Void, Never>?
    /// The bundle identifiers of what reported the track, from the latest update.
    @ObservationIgnored private var sourceBundleIdentifiers: [String] = []

    @ObservationIgnored private let adapter = MediaRemoteAdapter.locate()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var isRunning = false
    /// How long to wait before starting the adapter again after it exits: longer each time it exits without sending
    /// anything, so one that can't run isn't started every few seconds forever.
    @ObservationIgnored private var restartDelay = NowPlayingService.firstRestartDelay
    private static let firstRestartDelay: Duration = .seconds(3)
    /// The player's name and icon, worked out again only when another app plays: drawing the icon takes a moment.
    @ObservationIgnored private var player: (bundleIdentifier: String, name: String?, icon: NSImage?)?
    /// macOS reports a new track a moment before its artwork, and some apps resend the previous track's artwork first:
    /// Yandex Music sends none, the old one, none again, and the new one about 0.65 s after the track changed. For this
    /// long the notch keeps the previous artwork rather than blinking through those.
    @ObservationIgnored let artworkGrace: TimeInterval
    /// Whether the artwork of a new track is on its way. Until then the previous artwork, and its colors, stay.
    private(set) var isAwaitingArtwork = false
    /// Ends when the wait does; tests wait on it.
    @ObservationIgnored private(set) var artworkWait: Task<Void, Never>?
    /// The artwork shown when the track changed. Getting it again doesn't end the wait.
    @ObservationIgnored private var replacedArtworkData: Data?
    /// What the latest update brought, which stays when the wait runs out.
    @ObservationIgnored private var latestArtwork: (data: Data?, artwork: Artwork?) = (nil, nil)

    /// Yandex Music first sends the new title with everything else still from the previous track, and the rest about
    /// 0.54 s later. Updates like that wait this long at most for the rest, so the title and artist change together.
    @ObservationIgnored let earlyTitleWait: TimeInterval
    /// The latest of those updates, applied if the rest doesn't come.
    @ObservationIgnored private var earlyTitle: NowPlayingSnapshot?
    /// Ends when the wait for the rest does; tests wait on it.
    @ObservationIgnored private(set) var earlyTitleTask: Task<Void, Never>?

    init(
        artworkGrace: TimeInterval = 1,
        earlyTitleWait: TimeInterval = 1,
        isAudible: @escaping @MainActor ([String]) -> Bool? = AudibleApps.isAudible
    ) {
        self.artworkGrace = artworkGrace
        self.earlyTitleWait = earlyTitleWait
        self.isAudible = isAudible
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        launchStream()
    }

    func stop() {
        isRunning = false
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
    }

    /// Moves the track to `position`, within its length. The stream then reports where it is, if the player could.
    func seek(to position: TimeInterval) {
        guard let duration = track?.duration, duration > 0 else { return }
        adapter?.seek(to: min(max(position, 0), duration))
    }

    func send(_ command: MediaRemoteAdapter.Command) {
        adapter?.send(command)

        // Flip the play/pause button right away; the stream confirms the new state shortly after.
        if command == .togglePlayPause, var updated = track {
            let now = Date()
            updated.elapsedTime = updated.elapsedTime(at: now)
            updated.timestamp = now
            updated.isPlaying.toggle()
            track = updated
        }
    }

    // MARK: - Stream

    private func launchStream() {
        guard let adapter else {
            logger.error("mediaremote-adapter not found, now playing is disabled")
            return
        }

        let process = adapter.makeProcess(arguments: ["stream", "--no-diff", "--micros", "--debounce=100"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Called on a background thread, so it can't belong to the main actor.
        process.terminationHandler = { @Sendable [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.streamDidExit(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("Failed to start mediaremote-adapter: \(error.localizedDescription)")
            return
        }
        self.process = process

        let output = pipe.fileHandleForReading
        readTask = Task.detached(priority: .utility) { [weak self] in
            let decoder = JSONDecoder()
            // Updates repeat the artwork, so each new image is decoded once, here and not on the main actor.
            var decoded: (data: Data, artwork: Artwork?)?
            do {
                for try await line in output.bytes.lines {
                    guard let message = try? decoder.decode(AdapterStreamMessage.self, from: Data(line.utf8)),
                          message.type == "data"
                    else { continue }

                    var snapshot = NowPlayingSnapshot(payload: message.payload)
                    if let data = snapshot?.artworkData {
                        if decoded?.data != data {
                            decoded = (data, Artwork(data: data))
                        }
                        snapshot?.artwork = decoded?.artwork
                    }
                    await self?.apply(snapshot)
                }
            } catch {
                // The pipe closes when the adapter exits; `streamDidExit` takes care of restarting it.
            }
        }
    }

    private func streamDidExit(status: Int32) {
        process = nil
        guard isRunning else { return }

        let delay = restartDelay
        restartDelay = min(restartDelay * 2, .seconds(60))
        logger.warning("mediaremote-adapter exited with status \(status), restarting in \(delay)")
        track = nil
        artworkData = nil
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, isRunning, process == nil else { return }
            launchStream()
        }
    }

    /// Internal rather than private for the tests.
    func apply(_ snapshot: NowPlayingSnapshot?) {
        // The adapter works.
        restartDelay = Self.firstRestartDelay
        guard let snapshot else {
            track = nil
            artworkData = nil
            endArtworkWait()
            dropEarlyTitle()
            return
        }
        if let track, Self.isEarlyTitle(snapshot, after: track) {
            if earlyTitle == nil, snapshot.isPlaying {
                startIsReported = true
                sourceBundleIdentifiers = snapshot.sourceBundleIdentifiers
                reportOnceHeard(nil)
            }
            holdEarlyTitle(snapshot)
            return
        }
        dropEarlyTitle()
        update(with: snapshot)
    }

    private func update(with snapshot: NowPlayingSnapshot) {
        let previous = track
        let isNewItem = previous.map {
            $0.title != snapshot.title || $0.artist != snapshot.artist || $0.album != snapshot.album
        } ?? true
        if isNewItem {
            beginArtworkWait()
        }

        var artwork = previous?.artwork
        var artworkColor = previous?.artworkColor
        if isAwaitingArtwork {
            latestArtwork = (snapshot.artworkData, snapshot.artwork)
            if let data = snapshot.artworkData, data != replacedArtworkData {
                // The new track's own artwork.
                (artwork, artworkColor) = use(data, snapshot.artwork)
                endArtworkWait()
            }
        } else if let data = snapshot.artworkData, data != artworkData {
            // New artwork for the same track. Updates without any are left out: they come and go as tracks change.
            (artwork, artworkColor) = use(data, snapshot.artwork)
        }

        let app = playerApp(snapshot.appBundleIdentifier)

        let current = NowPlayingTrack(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            isPlaying: snapshot.isPlaying,
            playbackRate: snapshot.playbackRate,
            duration: snapshot.duration,
            elapsedTime: snapshot.elapsedTime,
            timestamp: snapshot.timestamp,
            artwork: artwork,
            appName: app?.name,
            appIcon: app?.icon,
            artworkColor: artworkColor
        )
        track = current
        sourceBundleIdentifiers = snapshot.sourceBundleIdentifiers
        if startIsReported {
            // The early title got the notch going already.
            startIsReported = false
            if current.isPlaying {
                starts.didReport(current)
            }
        } else if starts.isStart(current, at: .now) {
            reportOnceHeard(current)
        }
        if !current.isPlaying {
            audibleTask?.cancel()
            audibleTask = nil
            pendingStart = nil
            isSilent = false
        }
    }

    private func playerApp(_ bundleIdentifier: String?) -> (name: String?, icon: NSImage?)? {
        guard let bundleIdentifier else { return nil }
        if let player, player.bundleIdentifier == bundleIdentifier {
            return (player.name, player.icon)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") }
        let icon = url.flatMap { StandardRangeIcons.icon(forFile: $0.path(percentEncoded: false), points: 32) }
        player = (bundleIdentifier, name, icon)
        return (name, icon)
    }

    // MARK: - Starts that are heard

    /// Reports a start once its app sends sound, checking again while it plays. A muted YouTube preview never does,
    /// but opening that video then does. When it can't be told, the start is reported right away. `track` is nil for
    /// an early title, whose track isn't in yet.
    private func reportOnceHeard(_ track: NowPlayingTrack?) {
        let item = track.map(PlaybackStarts.Item.init)
        if item != nil, item == pendingStart, audibleTask != nil {
            // Waiting for this one already.
            return
        }
        audibleTask?.cancel()
        audibleTask = nil
        pendingStart = item
        if isAudible(sourceBundleIdentifiers) != false {
            isSilent = false
            report(track)
            return
        }
        isSilent = true
        // Often at first, as a preview opened as a video is heard at once; then less, as a muted video can play on.
        let started = ContinuousClock.now
        audibleTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = .now - started < .seconds(2) ? .milliseconds(200) : .seconds(1)
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.track?.isPlaying == true else { return }
                if isAudible(sourceBundleIdentifiers) != false {
                    audibleTask = nil
                    isSilent = false
                    report(self.track)
                    return
                }
            }
        }
    }

    private func report(_ track: NowPlayingTrack?) {
        pendingStart = nil
        if let track {
            starts.didReport(track)
        }
        onPlaybackStart?()
    }

    // MARK: - Early titles

    /// A new title with the artist, album, duration and position of the previous track, which no new track has.
    nonisolated static func isEarlyTitle(_ snapshot: NowPlayingSnapshot, after track: NowPlayingTrack) -> Bool {
        snapshot.title != track.title
            && snapshot.artist == track.artist
            && snapshot.album == track.album
            && snapshot.duration == track.duration
            && snapshot.elapsedTime == track.elapsedTime
    }

    private func holdEarlyTitle(_ snapshot: NowPlayingSnapshot) {
        earlyTitle = snapshot
        guard earlyTitleTask == nil else { return }
        earlyTitleTask = Task { [weak self, earlyTitleWait] in
            try? await Task.sleep(for: .seconds(earlyTitleWait))
            guard !Task.isCancelled, let self else { return }
            // The rest didn't come: perhaps the next track of an album, of the same length. Show it as it is.
            let held = earlyTitle
            dropEarlyTitle()
            if let held {
                update(with: held)
            }
        }
    }

    private func dropEarlyTitle() {
        earlyTitleTask?.cancel()
        earlyTitleTask = nil
        earlyTitle = nil
    }

    /// Shows this artwork from now on.
    private func use(_ data: Data?, _ decoded: Artwork?) -> (NSImage?, ArtworkColor?) {
        artworkData = data
        return (decoded.map { NSImage(cgImage: $0.image, size: .zero) }, decoded?.color)
    }

    // MARK: - Artwork on its way

    private func beginArtworkWait() {
        replacedArtworkData = artworkData
        latestArtwork = (nil, nil)
        isAwaitingArtwork = true
        artworkWait?.cancel()
        artworkWait = Task { [weak self, artworkGrace] in
            try? await Task.sleep(for: .seconds(artworkGrace))
            guard !Task.isCancelled else { return }
            self?.artworkWaitRanOut()
        }
    }

    /// No other artwork came: the next track of an album has the same one, or the track has none.
    private func artworkWaitRanOut() {
        artworkWait = nil
        isAwaitingArtwork = false
        guard var track else { return }
        (track.artwork, track.artworkColor) = use(latestArtwork.data, latestArtwork.artwork)
        self.track = track
    }

    private func endArtworkWait() {
        artworkWait?.cancel()
        artworkWait = nil
        isAwaitingArtwork = false
    }
}
