import AppKit

/// Where the notch is on a given screen, in global AppKit coordinates (origin at the bottom left).
struct NotchGeometry: Equatable {
    /// Size of the hardware notch, or of a virtual one on displays without a notch.
    let notchSize: CGSize
    /// Horizontal center of the notch.
    let notchMidX: CGFloat
    /// Frame of the screen the notch belongs to.
    let screenFrame: CGRect
    /// The display the notch is on.
    let displayID: CGDirectDisplayID?

    init(notchSize: CGSize, notchMidX: CGFloat, screenFrame: CGRect, displayID: CGDirectDisplayID? = nil) {
        self.notchSize = notchSize
        self.notchMidX = notchMidX
        self.screenFrame = screenFrame
        self.displayID = displayID
    }

    init(screen: NSScreen) {
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is whatever the two auxiliary areas next to it leave uncovered.
            let width = frame.width - left.width - right.width
            self.init(
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchMidX: frame.minX + left.width + width / 2,
                screenFrame: frame,
                displayID: screen.displayID
            )
        } else {
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            self.init(
                notchSize: CGSize(width: 200, height: max(menuBarHeight, 24)),
                notchMidX: frame.midX,
                screenFrame: frame,
                displayID: screen.displayID
            )
        }
    }

}

/// Which displays show a notch.
enum NotchDisplays: Hashable {
    /// The display with the pointer, so the notch follows the user from display to display.
    case automatic
    case all
    /// One display, or the automatic choice while it isn't connected.
    case display(CGDirectDisplayID)

    /// Picks from the displays connected now, the main display first, given the display with the pointer.
    func pick(
        from displays: [(id: CGDirectDisplayID, hasNotch: Bool)],
        pointerOn pointerDisplay: CGDirectDisplayID?
    ) -> [CGDirectDisplayID] {
        switch self {
        case .all:
            return displays.map(\.id)
        case .display(let id) where displays.contains(where: { $0.id == id }):
            return [id]
        case .automatic where displays.contains(where: { $0.id == pointerDisplay }):
            return pointerDisplay.map { [$0] } ?? []
        case .automatic, .display:
            // Without a pointer to follow, or with the chosen display unplugged: the one with a notch, or the main one.
            let display = displays.first(where: \.hasNotch) ?? displays.first
            return display.map { [$0.id] } ?? []
        }
    }

    /// The screens that show a notch now.
    @MainActor
    var screens: [NSScreen] {
        let screens = NSScreen.screens
        let picked = pick(
            from: screens.compactMap { screen in
                screen.displayID.map { (id: $0, hasNotch: screen.safeAreaInsets.top > 0) }
            },
            pointerOn: NSScreen.withPointer?.displayID
        )
        return picked.compactMap { id in screens.first { $0.displayID == id } }
    }
}

extension CGRect {
    /// Whether the pointer is in it, as macOS counts it: on the top edge too, where the pointer rests when it's pushed
    /// against the top of a display, which `contains` leaves out.
    func containsPointer(_ point: CGPoint) -> Bool {
        NSMouseInRect(point, self, false)
    }
}

extension NSScreen {
    /// The screen the pointer is on.
    @MainActor
    static var withPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { $0.frame.containsPointer(pointer) }
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
