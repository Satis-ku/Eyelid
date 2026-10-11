import SwiftUI

/// Where sound just went, on both sides of the closed notch. Headphones that report a charge show their icon and their
/// charge, with one earbud on its own side when the other is in the case. Other outputs look like the volume HUD: their
/// icon and their volume.
struct OutputActivityView: View {
    let event: OutputEvent
    let style: LevelStyle
    let notchSize: CGSize

    var body: some View {
        if event.battery == nil, let volume = event.volume {
            HUDView(
                event: HUDEvent(kind: .volume, level: volume.level, isMuted: volume.isMuted, deviceIcon: event.icon),
                style: style,
                notchSize: notchSize
            )
        } else {
            headphones
        }
    }

    private var headphones: some View {
        let sideWidth = NotchViewModel.Layout.hudSideWidth
        let earbud = event.battery?.singleEarbud
        let symbol = earbud.flatMap(event.icon.earbudSymbolName) ?? event.icon.availableSymbolName
        let iconIsOnTheRight = earbud == .right && symbol != event.icon.availableSymbolName

        // ZStacks, not Groups: a Group with nothing in it, as the level is for an output with no charge or volume,
        // takes no room at all, which pulled the icon under the hardware notch.
        return HStack(spacing: 0) {
            ZStack {
                if iconIsOnTheRight { level } else { icon(symbol) }
            }
            .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            ZStack {
                if iconIsOnTheRight { icon(symbol) } else { level }
            }
            .frame(width: sideWidth)
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var level: some View {
        if let level = event.battery?.level {
            HeadphonesBatteryLevel(level: level)
        }
    }

    private var accessibilityLabel: String {
        let name = switch event.battery?.singleEarbud {
        case .left: "\(event.name), left earbud"
        case .right: "\(event.name), right earbud"
        case nil: event.name
        }
        guard let level = event.battery?.level else { return "Sound on \(name)" }
        return "Sound on \(name), \(level)%"
    }
}

/// A ring and a percentage, as iOS shows AirPods.
private struct HeadphonesBatteryLevel: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(level) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)

            Text("\(level)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private var tint: Color {
        level <= 20 ? .red : .green
    }
}
