import SwiftUI

/// The Sound section of the open notch: the volume, the outputs to switch between, like the Sound menu in Control
/// Center, and the apps playing.
struct SoundPanel: View {
    let sound: SoundControl
    let appVolumes: AppVolumes
    let settings: AppSettings

    /// The slider's value while it's dragged, so reading the volume back doesn't fight it.
    @State private var level: Float = 0

    var body: some View {
        VStack(spacing: 8) {
            volumeRow
            HStack(alignment: .top, spacing: 14) {
                column("Output") {
                    // No ScrollView: it doesn't take the first click in a window that isn't key, which the notch
                    // never is.
                    ForEach(sound.devices.prefix(NotchViewModel.Layout.soundMaxRows)) { device in
                        OutputDeviceRow(
                            device: device,
                            icon: settings.icon(for: device),
                            isSelected: device.id == sound.defaultDeviceID
                        ) {
                            sound.select(device)
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
                        AudioAppRow(app: app, appVolumes: appVolumes)
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
            // Outputs come and go, and the volume changes elsewhere, while the tab shows.
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

            VolumeSlider(level: $level) { isEditing in
                sound.isAdjusting = isEditing
            }
            .onChange(of: level) { _, new in
                if sound.isAdjusting {
                    sound.setLevel(new)
                }
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
