import SwiftUI

/// A battery with its level written inside, as on iOS: the digits are cut out of the fill, so they read at any
/// charge. A bolt follows it while connected to power.
struct CompactBatteryIcon: View {
    let state: BatteryState

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.35))
                    Rectangle()
                        .fill(state.tint)
                        .frame(width: 27 * CGFloat(min(max(state.level, 0), 100)) / 100)
                    Text("\(state.level)")
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .blendMode(.destinationOut)
                }
                .frame(width: 27, height: 13)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.35))
                    .frame(width: 1.5, height: 4.5)
            }
            .compositingGroup()

            if state.isPluggedIn {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(state.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(state.level)%\(state.isPluggedIn ? ", connected to power" : "")")
    }
}

/// The date, time and battery right of the camera while the notch is open. Only as much as fits in the room there
/// shows: without the weekday, then without the date, so nothing goes under the camera.
struct OpenNotchStatus: View {
    let battery: BatteryState?
    let showsDate: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            ViewThatFits(in: .horizontal) {
                if showsDate {
                    status(date: .dateTime.weekday(.abbreviated).day().month(.abbreviated), at: context.date)
                    status(date: .dateTime.day().month(.abbreviated), at: context.date)
                    status(date: nil, at: context.date)
                }
                status(date: nil, at: nil)
            }
        }
    }

    /// Without AM or PM, which the menu bar's clock shows, so a 12-hour time leaves room for the date.
    static let time = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()

    private func status(date: Date.FormatStyle?, at now: Date?) -> some View {
        HStack(spacing: 6) {
            if let now {
                if let date {
                    Text(now, format: date)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(now, format: Self.time)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.trailing, 2)
            }
            if let battery {
                CompactBatteryIcon(state: battery)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// The time, and the battery, beside the closed notch while nothing plays, if that's turned on.
struct IdleActivityView: View {
    let battery: BatteryState?
    let notchSize: CGSize

    var body: some View {
        let sideWidth = NotchViewModel.Layout.activitySideWidth

        HStack(spacing: 0) {
            // A ZStack keeps its width with no battery, as on a Mac without one; an empty Group would take none and
            // pull the time under the hardware notch.
            ZStack {
                if let battery {
                    CompactBatteryIcon(state: battery)
                        .scaleEffect(0.85)
                }
            }
            .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            TimelineView(.everyMinute) { context in
                // "10:48 PM" doesn't fit beside the camera.
                Text(context.date, format: OpenNotchStatus.time)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: sideWidth)
        }
        .frame(height: notchSize.height)
    }
}

/// The battery on both sides of the hardware notch for a few seconds after a `BatteryEvent`.
struct BatteryActivityView: View {
    let event: BatteryEvent
    let notchSize: CGSize

    var body: some View {
        let state = event.state
        let sideWidth = NotchViewModel.Layout.activitySideWidth

        HStack(spacing: 0) {
            BatteryIcon(level: state.level, isPluggedIn: state.isPluggedIn, tint: state.tint)
                .frame(width: sideWidth)
            Spacer()
                .frame(width: notchSize.width)
            Text("\(state.level)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Clear of the camera, so "100%" shrinks a little rather than touch it.
                .padding(.horizontal, 3)
                .frame(width: sideWidth)
        }
        .frame(height: notchSize.height)
    }
}

/// A battery outline filled to the charge level, with a bolt while connected to power.
struct BatteryIcon: View {
    let level: Int
    let isPluggedIn: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(1.5, 19 * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2)
            }
            .frame(width: 23, height: 12)
            .overlay {
                if isPluggedIn {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }

            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }
}

extension BatteryState {
    /// Green on power, orange at 20% or less, red at 10% or less.
    var tint: Color {
        if isPluggedIn { return .green }
        if level <= 10 { return .red }
        if level <= 20 { return .orange }
        return .white
    }
}
