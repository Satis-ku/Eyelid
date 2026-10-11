import SwiftUI

/// An app's equalizer, in the Sound section: a slider for each band, and presets.
struct AppEqualizerPanel: View {
    let app: AudioApp
    let appVolumes: AppVolumes
    let close: @MainActor () -> Void

    private var settings: EqualizerSettings {
        appVolumes.equalizer(for: app)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .trailing) {
                    Text("+12")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("−12")
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 24)
                .padding(.bottom, 16)

                ForEach(EqualizerSettings.bands.indices, id: \.self) { band in
                    VStack(spacing: 4) {
                        BandSlider(gain: Binding(
                            get: { settings.gains[band] },
                            set: { gain in
                                var new = settings
                                new.gains[band] = gain
                                new.preset = nil
                                appVolumes.setEqualizer(EqualizerSettings(gains: new.gains), for: app)
                            }
                        ), label: Self.label(for: EqualizerSettings.bands[band]))
                        Text(Self.label(for: EqualizerSettings.bands[band]))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(height: 12)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Back to Sound")

            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Menu {
                ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                    Button(preset.title) {
                        appVolumes.setEqualizer(EqualizerSettings(preset), for: app)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(settings.preset?.title ?? (settings.isFlat ? EqualizerPreset.flat.title : "Custom"))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Preset")
        }
    }

    private static func label(for frequency: Double) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))K" : "\(Int(frequency))"
    }
}

/// One band's gain: a vertical track with 0 dB in the middle, filled from there to the gain, that follows a drag or
/// a click anywhere on it.
private struct BandSlider: View {
    @Binding var gain: Float
    let label: String
    @State private var isDragging = false
    @State private var isHovered = false

    private static let range = EqualizerSettings.range

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let middle = height / 2
            let position = middle - CGFloat(gain / Self.range.upperBound) * middle
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(isHovered || isDragging ? 0.22 : 0.14))
                    .frame(width: 4)
                Rectangle()
                    .fill(.white)
                    .frame(width: 4, height: abs(position - middle))
                    .offset(y: min(position, middle))
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 12 : 10, height: isDragging ? 12 : 10)
                    .offset(y: position - (isDragging ? 6 : 5))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let fraction = Float((middle - value.location.y) / max(middle, 1))
                        let raw = min(max(fraction, -1), 1) * Self.range.upperBound
                        // Half-decibel steps, and 0 dB is easy to land on.
                        let stepped = (raw * 2).rounded() / 2
                        gain = abs(stepped) < 0.75 ? 0 : stepped
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isDragging)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue("\(gain.formatted(.number.precision(.fractionLength(0...1)))) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gain = min(gain + 1, Self.range.upperBound)
            case .decrement: gain = max(gain - 1, Self.range.lowerBound)
            @unknown default: break
            }
        }
    }
}
