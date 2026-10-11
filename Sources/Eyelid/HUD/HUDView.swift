import SwiftUI

/// The volume or brightness on both sides of the hardware notch: an icon on the left, the level on the right.
struct HUDView: View {
    let event: HUDEvent
    let style: LevelStyle
    let notchSize: CGSize

    /// As wide as the speaker with all its waves.
    static let iconWidth: CGFloat = 22

    var body: some View {
        let sideWidth = NotchViewModel.Layout.hudSideWidth

        HStack(spacing: 0) {
            Image(systemName: event.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(event.dimsIcon ? 0.4 : 1))
                .contentTransition(.symbolEffect(.replace))
                // The speaker's waves grow to the right, so the speaker itself stays put as the level changes.
                .frame(width: Self.iconWidth, alignment: event.hasWaves ? .leading : .center)
                .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            LevelIndicator(level: event.isMuted ? 0 : event.level, style: style)
                .frame(width: sideWidth)
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.kind == .volume ? "Volume" : "Brightness")
        .accessibilityValue(event.isMuted ? "Muted" : "\(Int((event.level * 100).rounded())) percent")
    }
}

struct LevelIndicator: View {
    let level: Float
    let style: LevelStyle

    private var clamped: CGFloat { CGFloat(min(max(level, 0), 1)) }

    var body: some View {
        Group {
            switch style {
            case .bar:
                CapsuleBar(level: clamped, height: 5)
            case .thickBar:
                CapsuleBar(level: clamped, height: 10)
            case .segments:
                HStack(spacing: 1) {
                    ForEach(0..<LevelStyle.segmentCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(.white.opacity(index < LevelStyle.litSegments(for: level) ? 1 : 0.22))
                            .frame(width: 2, height: 9)
                    }
                }
            case .percentage:
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            case .ring:
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

private struct CapsuleBar: View {
    let level: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(.white)
                .frame(width: 48 * level)
        }
        .frame(width: 48, height: height)
    }
}

/// A sample HUD on a black pill, for picking a level style in Settings.
struct HUDPreview: View {
    let style: LevelStyle

    var body: some View {
        HUDView(event: HUDEvent(kind: .volume, level: 0.625), style: style, notchSize: CGSize(width: 40, height: 32))
            .background(.black, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}
