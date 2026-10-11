import SwiftUI

/// The expanded now playing card: artwork, title, progress and controls.
struct NowPlayingCard: View {
    let track: NowPlayingTrack
    let nowPlaying: NowPlayingService

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: track.artwork, appIcon: track.appIcon, size: 72, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(track.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)

                PlaybackProgressView(track: track)

                PlaybackControls(isPlaying: track.isPlaying) { command in
                    nowPlaying.send(command)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Artwork and equalizer on both sides of the hardware notch while something plays.
struct ClosedActivityView: View {
    let track: NowPlayingTrack
    let notchSize: CGSize
    var levels: [Double]? = nil
    /// The pointer is over the equalizer, which takes clicks: it lights up a little.
    var isEqualizerHovered = false
    /// A click on the equalizer opens the Sound tab.
    var openSound: @MainActor () -> Void = {}

    var body: some View {
        let sideWidth = NotchViewModel.Layout.activitySideWidth

        HStack(spacing: 0) {
            ArtworkView(artwork: track.artwork, appIcon: nil, size: notchSize.height - 12, cornerRadius: 5)
                .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            Button(action: openSound) {
                EqualizerView(isPlaying: track.isPlaying, levels: levels)
                    .scaleEffect(isEqualizerHovered ? 1.15 : 1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(isEqualizerHovered ? 0.16 : 0))
                    )
                    .frame(width: sideWidth, height: notchSize.height)
                    .contentShape(Rectangle())
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isEqualizerHovered)
            }
            .buttonStyle(PressableButtonStyle())
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
            ControlButton(systemImage: "backward.fill", size: 14) { send(.previousTrack) }
            ControlButton(systemImage: isPlaying ? "pause.fill" : "play.fill", size: 20) { send(.togglePlayPause) }
            ControlButton(systemImage: "forward.fill", size: 14) { send(.nextTrack) }
        }
    }
}

private struct ControlButton: View {
    let systemImage: String
    let size: CGFloat
    let action: @MainActor () -> Void

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
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct EqualizerView: View {
    let isPlaying: Bool
    /// The sound itself, one level a bar from 0 to 1, when Eyelid listens to it. Otherwise the bars move on their own.
    var levels: [Double]? = nil

    private let speeds: [Double] = [5.1, 6.7, 4.3, 7.9]

    var body: some View {
        if let levels, isPlaying {
            bars(speeds.indices.map { index in
                3 + 11 * CGFloat(levels.indices.contains(index) ? levels[index] : 0)
            })
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
