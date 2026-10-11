import AppKit
import os

private let logger = Logger(subsystem: "io.github.satis-ku.eyelid", category: "Translation")

/// Tells text copied twice in a row, with ⌘C pressed twice, which asks for a translation.
struct DoubleCopy {
    /// The second copy comes within this long of the first.
    static let window: Duration = .milliseconds(600)

    private var lastCopy: ContinuousClock.Instant?

    /// Whether a copy seen at `now` is the second of two. A third one starts over, so ⌘C pressed three times
    /// translates once.
    mutating func isSecond(at now: ContinuousClock.Instant) -> Bool {
        if let lastCopy, now - lastCopy <= Self.window {
            self.lastCopy = nil
            return true
        }
        lastCopy = now
        return false
    }
}

/// Watches the pasteboard for text copied twice in a row. It only looks at the change count and the kinds of data
/// copied, which needs no permission; the text itself is read once a translation is asked for.
@MainActor
final class DoubleCopyWatcher {
    var onDoubleCopy: (@MainActor () -> Void)?

    /// Often enough to see both copies of ⌘C pressed twice. Reading the change count costs well under a microsecond.
    static let interval: Duration = .milliseconds(50)

    private let pasteboard: NSPasteboard
    private var detector = DoubleCopy()
    private var lastChangeCount: Int
    private var watchTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func setWatching(_ isOn: Bool) {
        watchTask?.cancel()
        watchTask = nil
        logger.debug("Watching for text copied twice: \(isOn, privacy: .public)")
        guard isOn else { return }

        lastChangeCount = pasteboard.changeCount
        watchTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: Self.interval, tolerance: Self.interval / 4)
                } catch {
                    return
                }
                self?.check(at: .now)
            }
        }
    }

    /// Looks at the pasteboard once. Several changes since the last look are one copy: some apps write more than
    /// once for a single ⌘C, and nobody presses it twice within one interval.
    func check(at now: ContinuousClock.Instant) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard detector.isSecond(at: now) else { return }
        logger.debug("Copied twice")
        // Text only, and never what a password manager marks as concealed.
        guard let types = pasteboard.types, types.contains(.string),
              ClipboardHistory.skippedMarkers.isDisjoint(with: types)
        else { return }
        onDoubleCopy?()
    }
}
