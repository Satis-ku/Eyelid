import SwiftUI

/// One output in the Sound section: its icon, name and headphone charge, with a check on the one in use.
struct OutputDeviceRow: View {
    let device: OutputDevice
    let icon: DeviceIcon
    let batteryLevel: Int?
    let isSelected: Bool
    let select: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: icon.availableSymbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.6))
                Text(device.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
                    .lineLimit(1)
                    // A column is half the notch wide: names like "MacBook Pro Speakers" shrink a little first.
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let level = batteryLevel {
                    Text("\(level)%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(level <= 20 ? .red : .white.opacity(0.5))
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                .white.opacity(isSelected ? 0.1 : (isHovered ? 0.06 : 0)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(hoverScale: 1))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
