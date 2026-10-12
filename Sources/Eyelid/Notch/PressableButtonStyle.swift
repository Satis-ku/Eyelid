import SwiftUI

/// The notch's buttons: they grow a little under the pointer, with a spring, and shrink when pressed.
struct PressableButtonStyle: ButtonStyle {
    /// How much the button grows under the pointer. Rows across the notch don't, and light up instead.
    var hoverScale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        PressableButton(configuration: configuration, hoverScale: hoverScale)
    }
}

private struct PressableButton: View {
    let configuration: ButtonStyleConfiguration
    let hoverScale: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            // With Reduce Motion, a press only dims.
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.88 : (isHovered ? hoverScale : 1)))
            .onHover { isHovered = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
