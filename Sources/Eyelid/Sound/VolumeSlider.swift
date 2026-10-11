import SwiftUI

/// A white capsule filled to the volume, like the HUD's level bar, that follows a drag or a click anywhere on it.
struct VolumeSlider: View {
    @Binding var level: Float
    var accessibilityLabel = "Volume"
    /// Called as a drag starts and ends, so reading the volume back doesn't fight it.
    let onEditingChanged: @MainActor (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                Capsule()
                    .fill(.white)
                    .frame(width: max(6, proxy.size.width * CGFloat(level)))
            }
            .frame(height: isDragging ? 8 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        level = Float(min(max(value.location.x / max(proxy.size.width, 1), 0), 1))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            onEditingChanged(true)
            switch direction {
            case .increment: level = min(level + 1 / 16, 1)
            case .decrement: level = max(level - 1 / 16, 0)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}
