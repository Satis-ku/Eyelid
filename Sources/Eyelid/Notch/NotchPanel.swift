import AppKit
import SwiftUI

/// A transparent, borderless panel that floats above the menu bar on every Space,
/// including full-screen ones, without ever activating the app.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Clicks pass through to the menu bar until the notch opens.
        ignoresMouseEvents = true
    }

    /// True while the clipboard history or the translator holds the notch open, so it can take the keyboard. Being a
    /// non-activating panel, it does so without activating Eyelid: the app in front stays in front and gets the
    /// keyboard back after.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    // Keep AppKit from pushing the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets buttons react to the first click, though the panel is mostly not key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
