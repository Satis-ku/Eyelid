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

                PlaybackProgressView(track: track) { position in
                    nowPlaying.seek(to: position)
                }

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
    /// A click on the equalizer opens the Sound section.
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

/// The track's progress, which a click or a drag moves, as in Control Center. The seek goes once the pointer lets go,
/// and the bar stays where it went while the player catches up.
struct PlaybackProgressView: View {
    let track: NowPlayingTrack
    let seek: @MainActor (TimeInterval) -> Void

    /// Where the pointer has dragged to, while it does.
    @State private var dragged: TimeInterval?
    /// The last seek, and when it was asked for.
    @State private var sought: Seek?
    @State private var isHovered = false

    struct Seek {
        let position: TimeInterval
        let at: Date
    }

    /// How long a seek shows before the bar goes back to what the player reports: one that can't seek never gets
    /// there, and the bar shouldn't stay where it never went.
    static let seekGrace: TimeInterval = 3
    /// How close the player's position must come to the seek for the bar to follow the player again.
    static let seekTolerance: TimeInterval = 1.5
    /// How far VoiceOver's adjustments move.
    private static let step: TimeInterval = 10

    var body: some View {
        if let duration = track.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = Self.position(at: context.date, of: track, dragged: dragged, sought: sought)

                HStack(spacing: 8) {
                    Text(Self.format(elapsed))
                    bar(elapsed: elapsed, duration: duration)
                    Text("-" + Self.format(duration - elapsed))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(Self.format(Self.position(at: .now, of: track, dragged: nil, sought: sought))) of \(Self.format(duration))"
            )
            .accessibilityAdjustableAction { direction in
                let now = Self.position(at: .now, of: track, dragged: nil, sought: sought)
                switch direction {
                case .increment: go(to: now + Self.step, of: duration)
                case .decrement: go(to: now - Self.step, of: duration)
                @unknown default: break
                }
            }
        }
    }

    private func bar(elapsed: TimeInterval, duration: TimeInterval) -> some View {
        GeometryReader { proxy in
            let isActive = isHovered || dragged != nil
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(isActive ? 0.28 : 0.2))
                Capsule()
                    .fill(.white.opacity(isActive ? 1 : 0.9))
                    .frame(width: proxy.size.width * min(elapsed / duration, 1))
            }
            .frame(height: isActive ? 7 : 4)
            .frame(maxHeight: .infinity)
            // The whole row's height takes the pointer, not only the thin bar.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragged = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        go(to: min(max(value.location.x / width, 0), 1) * duration, of: duration)
                        dragged = nil
                    }
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
    }

    private func go(to position: TimeInterval, of duration: TimeInterval) {
        let position = min(max(position, 0), duration)
        sought = Seek(position: position, at: .now)
        seek(position)
    }

    /// Where the bar is: where it's dragged to, or where a seek went until the player gets there, for a moment at
    /// most, or else where the player says it is.
    ///
    /// The player's position counts once it's near the seek, not merely once it's newer: while seeking, players
    /// report a fresh update or two with the old position, which pulled the bar back for a moment.
    static func position(at date: Date, of track: NowPlayingTrack, dragged: TimeInterval?, sought: Seek?) -> TimeInterval {
        if let dragged {
            return dragged
        }
        let reported = track.elapsedTime(at: date) ?? 0
        guard let sought, date.timeIntervalSince(sought.at) < seekGrace else { return reported }
        let played = track.isPlaying ? max(date.timeIntervalSince(sought.at) * track.playbackRate, 0) : 0
        let expected = min(sought.position + played, track.duration ?? .infinity)
        return abs(reported - expected) < seekTolerance ? reported : expected
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
