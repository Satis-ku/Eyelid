import SwiftUI

/// The Sound tab of the open notch: the volume, and the outputs to switch between, like the Sound menu in Control
/// Center.
struct SoundPanel: View {
    let sound: SoundControl
    let settings: AppSettings

    /// The slider's value while it's dragged, so reading the volume back doesn't fight it.
    @State private var level: Float = 0

    var body: some View {
        VStack(spacing: 8) {
            volumeRow
            // No ScrollView: it doesn't take the first click in a window that isn't key, which the notch never is.
            VStack(spacing: 2) {
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
