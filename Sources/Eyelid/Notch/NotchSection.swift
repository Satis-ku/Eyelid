/// A section of the open notch, in the dock at its bottom or the menu of all sections.
enum NotchSection: String, CaseIterable, Sendable {
    case nowPlaying
    case shelf
    case clipboard
    case sound
    case translation

    /// The dock keeps this many pinned sections at most, so each has room and it doesn't look crowded. The rest are a
    /// click away in the menu of all sections.
    static let maxPinned = 6

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .sound: "Sound"
        case .translation: "Translation"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: "music.note"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .sound: "speaker.wave.2"
        case .translation: "translate"
        }
    }

    /// Every section once, in the order stored, with sections unknown when it was stored, such as new ones, at the
    /// end. Names no longer known are dropped.
    static func order(from stored: [String]?) -> [NotchSection] {
        let known = (stored ?? []).compactMap(NotchSection.init(rawValue:))
        var seen = Set<NotchSection>()
        let unique = known.filter { seen.insert($0).inserted }
        return unique + allCases.filter { !seen.contains($0) }
    }
}
