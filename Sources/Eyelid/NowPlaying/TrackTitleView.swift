import SwiftUI

/// The track title running along the lower lid: in from its right corner, along the curve, out at its left one, in the
/// colors of the artwork. Each character sits on the curve, turned to follow it.
struct TrackTitleView: View {
    let title: TrackTitle
    let line: TitleLine
    let color: ArtworkColor?
    /// The lid: its width, and how far it hangs below the hardware notch.
    let size: CGSize
    /// How far above the bottom of the lid the text runs.
    let inset: CGFloat
    /// Called once the text has left at the left corner.
    let onFinish: @MainActor () -> Void

    /// Near the corners the lid is too shallow for the text, which fades in and out over this much depth.
    private static let fadeDepth: CGFloat = 6
    /// How long the previous track's colors take to flow into the new artwork's.
    private static let colorBlend: TimeInterval = 0.4

    /// The colors being left behind, and when the blend into `color` began. A canvas doesn't animate on its own.
    @State private var blend: (from: ArtworkColor, startedAt: Date)?

    private static func textColor(_ color: ArtworkColor?) -> ArtworkColor {
        color?.legibleOnBlack ?? ArtworkColor(red: 1, green: 1, blue: 1)
    }

    var body: some View {
        let curve = LidCurve(width: size.width, depth: size.height, inset: inset)
        let duration = TrackTitle.duration(textWidth: line.width, pathLength: curve.length)
        let target = Self.textColor(color)

        // 60 frames a second is smooth enough for text running this slowly, and half the work on a 120 Hz display.
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let elapsed = context.date.timeIntervalSince(title.startedAt)
            let start = TrackTitle.textStart(after: elapsed, textWidth: line.width, pathLength: curve.length)
            let tint = tint(at: context.date, target: target).color

            Canvas { canvas, _ in
                // Every character has the same font size, so where its baseline sits is worked out once.
                var anchor: UnitPoint?
                for character in line.characters {
                    guard let point = curve.point(at: start + character.offset + character.width / 2) else { continue }
                    // The character's top must clear the hardware notch.
                    let clearance = point.position.y - TrackTitle.fontSize
                    let opacity = min(max(clearance / Self.fadeDepth, 0), 1)
                    guard opacity > 0 else { continue }

                    let text = canvas.resolve(
                        Text(character.text)
                            .font(.system(size: TrackTitle.fontSize, weight: character.isDetail ? .medium : .semibold))
                            .foregroundStyle(character.isDetail ? tint.opacity(0.7) : tint)
                    )
                    if anchor == nil {
                        let room = CGSize(width: 100, height: 100)
                        let height = text.measure(in: room).height
                        anchor = UnitPoint(x: 0.5, y: height > 0 ? text.firstBaseline(in: room) / height : 1)
                    }

                    var glyph = canvas
                    glyph.opacity = opacity
                    glyph.translateBy(x: point.position.x, y: point.position.y)
                    glyph.rotate(by: .radians(point.angle))
                    glyph.draw(text, at: .zero, anchor: anchor ?? .bottom)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // The previous track's colors flow into the new artwork's as it arrives.
        .onChange(of: color) { old, _ in
            blend = (tint(at: .now, target: Self.textColor(old)), .now)
        }
        // Ends when the text has run past, which takes longer once the full title is in.
        .task(id: duration) {
            let remaining = duration - Date.now.timeIntervalSince(title.startedAt)
            try? await Task.sleep(for: .seconds(max(remaining, 0)))
            guard !Task.isCancelled else { return }
            onFinish()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([line.title, line.artist].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Partway from the colors left behind to the target, easing in and out.
    private func tint(at date: Date, target: ArtworkColor) -> ArtworkColor {
        guard let blend else { return target }
        let progress = min(max(date.timeIntervalSince(blend.startedAt) / Self.colorBlend, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        return ArtworkColor(
            red: blend.from.red + (target.red - blend.from.red) * eased,
            green: blend.from.green + (target.green - blend.from.green) * eased,
            blue: blend.from.blue + (target.blue - blend.from.blue) * eased
        )
    }
}
