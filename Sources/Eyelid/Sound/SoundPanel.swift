import SwiftUI

/// The Sound section of the open notch: the volume, the outputs to switch between, like the Sound menu in Control
/// Center, and the apps playing.
struct SoundPanel: View {
    let sound: SoundControl
    let appVolumes: AppVolumes
    let settings: AppSettings

    /// The slider's value while it's dragged, so reading the volume back doesn't fight it.
    @State private var level: Float = 0
    /// The app whose equalizer shows in place of the outputs and apps.
    @State private var equalizing: AudioApp?

    var body: some View {
        if let app = equalizing {
            AppEqualizerPanel(app: app, appVolumes: appVolumes) {
                equalizing = nil
            }
        } else {
            mixer
        }
    }

    private var mixer: some View {
        VStack(spacing: 8) {
            volumeRow
            HStack(alignment: .top, spacing: 14) {
                column("Output") {
                    // No ScrollView: it doesn't take the first click in a window that isn't key, which the notch
                    // mostly isn't. Outputs that don't fit are in Sound Settings, from the last row.
                    let rows = NotchViewModel.Layout.soundMaxRows
                    let overflows = sound.devices.count > rows
                    ForEach(sound.devices.prefix(overflows ? rows - 1 : rows)) { device in
                        OutputDeviceRow(
                            device: device,
                            icon: settings.icon(for: device),
                            batteryLevel: sound.batteryLevels[device.id],
                            isSelected: device.id == sound.defaultDeviceID
                        ) {
                            sound.select(device)
                        }
                    }
                    if overflows {
                        MoreOutputsRow(count: sound.devices.count - (rows - 1)) {
                            NSWorkspace.shared.open(Self.soundSettings)
                        }
                    }
                }
                column("Playing") {
                    if sound.apps.isEmpty {
                        Text("No app is playing")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(height: NotchViewModel.Layout.soundRowHeight - 2)
                            .padding(.horizontal, 8)
                    }
                    ForEach(sound.apps.prefix(NotchViewModel.Layout.soundMaxRows)) { app in
                        AudioAppRow(app: app, appVolumes: appVolumes) {
                            equalizing = app
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Sound Settings…") {
                    NSWorkspace.shared.open(Self.soundSettings)
                }
                .buttonStyle(PressableButtonStyle(hoverScale: 1.05))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .task {
            // Outputs come and go, and the volume changes elsewhere, while the section shows.
            while !Task.isCancelled {
                sound.refresh()
                if !sound.isAdjusting {
                    level = sound.volume.level
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .frame(height: NotchViewModel.Layout.soundHeaderHeight, alignment: .bottom)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button(sound.volume.isMuted ? "Unmute" : "Mute", systemImage: muteSymbol) {
                sound.toggleMute()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(PressableButtonStyle())
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22)

            // Set from the slider only, by a drag, a click or VoiceOver; reading the volume back leaves it alone.
            VolumeSlider(level: Binding(get: { level }, set: { new in
                level = new
                sound.setLevel(new)
            })) { isEditing in
                sound.isAdjusting = isEditing
            }

            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 34, alignment: .trailing)
        }
        .disabled(!sound.canSetVolume)
        .opacity(sound.canSetVolume ? 1 : 0.4)
    }

    private var muteSymbol: String {
        if sound.volume.isMuted || level == 0 { return "speaker.slash.fill" }
        if level < 1 / 3 { return "speaker.wave.1.fill" }
        if level < 2 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
}

/// The last row of outputs when there are more than fit: opens Sound Settings, which lists them all.
private struct MoreOutputsRow: View {
    let count: Int
    let open: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20)
                Text("\(count) More…")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.white.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel("\(count) more outputs, in Sound Settings")
    }
}
