import SwiftUI

/// An app playing, in the Sound section: its icon, which brings it forward, its name, and its own volume.
struct AudioAppRow: View {
    let app: AudioApp
    let appVolumes: AppVolumes
    /// Opens the app's equalizer.
    let equalize: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                guard let url = app.bundleURL else { return }
                // Opening a running app brings it forward, which activating it from an app in the background may not.
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } label: {
                HStack(spacing: 6) {
                    icon
                        .frame(width: 18, height: 18)
                    Text(app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .frame(width: 92, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(hoverScale: 1.04))
            .help("Show \(app.name)")
            .accessibilityHint("Brings the app forward")

            if AudioProperty.canTapProcesses {
                VolumeSlider(
                    level: Binding(
                        get: { appVolumes.volume(for: app) },
                        set: { appVolumes.setVolume($0, for: app) }
                    ),
                    accessibilityLabel: "Volume of \(app.name)"
                ) { isEditing in
                    // Settles whether the app still needs a tap of its own once the slider is let go.
                    if !isEditing {
                        appVolumes.sync()
                    }
                }

                Button(action: equalize) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 11, weight: .semibold))
                        // Lit while the app has an equalizer of its own.
                        .foregroundStyle(.white.opacity(appVolumes.equalizer(for: app).isFlat ? 0.45 : 1))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Equalizer for \(app.name)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            .white.opacity(isHovered ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var icon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
