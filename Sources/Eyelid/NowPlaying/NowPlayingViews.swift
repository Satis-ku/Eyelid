import SwiftUI

/// The expanded now playing card: artwork, title, progress and controls.
struct NowPlayingCard: View {
    let track: NowPlayingTrack
    let nowPlaying: NowPlayingService

    /// The artwork's side, and the height of the title, progress and controls beside it.
    private static let artworkSize: CGFloat = 120

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: track.artwork, appIcon: track.appIcon, size: Self.artworkSize, cornerRadius: 16)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(track.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                PlaybackProgressView(track: track)

                PlaybackControls(isPlaying: track.isPlaying) { command in
                    nowPlaying.send(command)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .frame(height: Self.artworkSize)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Artwork and equalizer on both sides of the hardware notch while something plays.
struct ClosedActivityView: View {
    let track: NowPlayingTrack
    let notchSize: CGSize
    /// Read by the equalizer alone, which redraws with every level, so the rest of the notch doesn't.
    var audioLevels: AudioLevels? = nil
    /// The pointer is over the equalizer, which takes clicks: it lights up a little.
    var isEqualizerHovered = false
    /// A click on the equalizer opens the Sound tab.
    var openSound: @MainActor () -> Void = {}

    var body: some View {
        let sideWidth = NotchViewModel.Layout.activitySideWidth

        HStack(spacing: 0) {
            // The player's icon when there's no artwork: a placeholder this small can hardly be seen.
            ArtworkView(artwork: track.artwork ?? track.appIcon, appIcon: nil, size: notchSize.height - 12, cornerRadius: 5)
                .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            Button(action: openSound) {
                EqualizerView(isPlaying: track.isPlaying, audioLevels: audioLevels)
                    .scaleEffect(isEqualizerHovered ? 1.15 : 1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(
                        .white.opacity(isEqualizerHovered ? 0.16 : 0),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .frame(width: sideWidth, height: notchSize.height)
                    .contentShape(Rectangle())
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isEqualizerHovered)
            }
            // It grows on its own, as the window controller sees the pointer over it.
            .buttonStyle(PressableButtonStyle(hoverScale: 1))
            .accessibilityLabel("Sound")
        }
        .frame(height: notchSize.height)
    }
}

struct ArtworkView: View {
    let artwork: NSImage?
    /// Shown as a small badge in the corner, like on iOS.
    let appIcon: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: size * 0.38, height: size * 0.38)
                    .offset(x: 6, y: 6)
            }
        }
    }
}

struct PlaybackProgressView: View {
    let track: NowPlayingTrack

    var body: some View {
        if let duration = track.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = track.elapsedTime(at: context.date) ?? 0

                HStack(spacing: 8) {
                    Text(Self.format(elapsed))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(.white.opacity(0.9))
                                .frame(width: proxy.size.width * min(elapsed / duration, 1))
                        }
                    }
                    .frame(height: 4)
                    Text("-" + Self.format(duration - elapsed))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(height: 14)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%d:%02d", minutes, seconds % 60)
    }
}

struct PlaybackControls: View {
    let isPlaying: Bool
    let send: @MainActor (MediaRemoteAdapter.Command) -> Void

    var body: some View {
        HStack(spacing: 28) {
            ControlButton("Previous Track", systemImage: "backward.fill", size: 14) { send(.previousTrack) }
            ControlButton(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill", size: 20) {
                send(.togglePlayPause)
            }
            ControlButton("Next Track", systemImage: "forward.fill", size: 14) { send(.nextTrack) }
        }
    }
}

private struct ControlButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let size: CGFloat
    let action: @MainActor () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, size: CGFloat, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }
}

/// The notch's buttons: they grow a little under the pointer, with a spring, and shrink when pressed.
struct PressableButtonStyle: ButtonStyle {
    /// How much the button grows under the pointer. Rows across the notch don't, and light up instead.
    var hoverScale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        PressableButton(configuration: configuration, hoverScale: hoverScale)
    }
}

private struct PressableButton: View {
    let configuration: ButtonStyleConfiguration
    let hoverScale: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            // With Reduce Motion, a press only dims.
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.88 : (isHovered ? hoverScale : 1)))
            .onHover { isHovered = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct EqualizerView: View {
    let isPlaying: Bool
    /// The sound itself, one level a bar from 0 to 1, when Eyelid listens to it. Otherwise the bars move on their own.
    var audioLevels: AudioLevels? = nil

    private let speeds: [Double] = [5.1, 6.7, 4.3, 7.9]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let levels = audioLevels?.levels, isPlaying {
            bars(speeds.indices.map { index in
                3 + 11 * CGFloat(levels.indices.contains(index) ? levels[index] : 0)
            })
        } else if reduceMotion {
            // Bars that stand still, at heights that still read as sound.
            bars(isPlaying ? [8, 12, 6, 10] : [3, 3, 3, 3])
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isPlaying)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                bars(speeds.indices.map { barHeight(index: $0, time: time) })
            }
        }
    }

    private func bars(_ heights: [CGFloat]) -> some View {
        HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: heights[index])
            }
        }
        .frame(height: 14)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return 3 }
        let wave = sin(time * speeds[index] + Double(index) * 1.3)
        return 4 + 10 * CGFloat((wave + 1) / 2)
    }
}
