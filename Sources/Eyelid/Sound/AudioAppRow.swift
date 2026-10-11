import SwiftUI

/// An app playing, in the Sound section: its icon and name. A click brings it forward.
struct AudioAppRow: View {
    let app: AudioApp
    @State private var isHovered = false

    var body: some View {
        Button {
            guard let url = app.bundleURL else { return }
            // Opening a running app brings it forward, which activating it from an app in the background may not.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                .white.opacity(isHovered ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(app.name)
        .accessibilityHint("Brings the app forward")
    }
}
