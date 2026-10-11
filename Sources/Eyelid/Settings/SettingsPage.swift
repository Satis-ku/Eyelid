import SwiftUI

/// A page of Settings, in the sidebar.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case sections
    case nowPlaying
    case volumeAndBrightness
    case battery
    case shelf
    case clipboard
    case translation
    case about

    var id: Self { self }

    /// The features, grouped together in the sidebar.
    static let features: [SettingsPage] = [.nowPlaying, .volumeAndBrightness, .battery, .shelf, .clipboard, .translation]

    var title: String {
        switch self {
        case .general: "General"
        case .sections: "Sections"
        case .nowPlaying: "Now Playing"
        case .volumeAndBrightness: "Volume & Brightness"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .translation: "Translation"
        case .about: "About"
        }
    }

    /// What the page is about, under its title.
    var summary: String {
        switch self {
        case .general: "How the notch opens, where, and what it shows beside the camera."
        case .sections: "The dock at the bottom of the open notch, and the order of every section."
        case .nowPlaying: "What plays, beside the notch and in it."
        case .volumeAndBrightness: "The volume, brightness and sound outputs as they change."
        case .battery: "Charging, unplugging and a low battery."
        case .shelf: "Files kept at hand in the notch."
        case .clipboard: "What you copied lately, a shortcut away."
        case .translation: "Text translated on this Mac, in the notch."
        case .about: "Eyelid, its version and its license."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .sections: "dock.rectangle"
        case .nowPlaying: "music.note"
        case .volumeAndBrightness: "speaker.wave.2.fill"
        case .battery: "battery.75percent"
        case .shelf: "tray.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .translation: "translate"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .sections: .blue
        case .nowPlaying: .pink
        case .volumeAndBrightness: .indigo
        case .battery: .green
        case .shelf: .orange
        case .clipboard: .cyan
        case .translation: .purple
        case .about: .gray
        }
    }
}

/// The page's symbol, white on a square of its color, as in System Settings.
struct SettingsPageIcon: View {
    let page: SettingsPage
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(page.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                // Scaled to fit, since some symbols, such as Translation's, are much wider than others.
                Image(systemName: page.systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: size * 0.6, height: size * 0.6)
            }
            .accessibilityHidden(true)
    }
}

/// The page's icon, title and summary, at the top of the page.
struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SettingsPageIcon(page: page, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title3.weight(.semibold))
                Text(page.summary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
