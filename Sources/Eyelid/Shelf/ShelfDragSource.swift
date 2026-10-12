import AppKit
import SwiftUI

/// Drags files out of the shelf.
///
/// It outlives the views a drag starts from: the notch closes as soon as the pointer leaves it,
/// while the drag goes on until the file is dropped.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    /// Called once the files of a drag were dropped somewhere that took them.
    var onDrop: (([ShelfItem.ID]) -> Void)?
    private var draggedItems: [ShelfItem.ID] = []

    /// Drags one file with `image` in `frame`, or several fanned out from there, each with its own icon.
    func beginDrag(of items: [ShelfItem], image: NSImage, frame: CGRect, event: NSEvent, from view: NSView) {
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let contents = index == 0 ? image : ShelfThumbnails.image(for: item.url)
            draggingItem.setDraggingFrame(frame.offsetBy(dx: CGFloat(index) * 6, dy: CGFloat(index) * 6), contents: contents)
            return draggingItem
        }
        draggedItems = items.map(\.id)
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Elsewhere the drop works as if the file came from Finder: moved within a disk, copied across disks or with ⌥.
        // Within Eyelid, the only place to drop it is the shelf it came from.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let items = draggedItems
        draggedItems = []
        if operation != [] {
            onDrop?(items)
        }
    }
}

/// The mouse on a shelf tile: drag to take the file out, double-click to open it, right-click for a menu.
/// The tile for all the files drags them all.
struct ShelfTileMouseArea: NSViewRepresentable {
    let items: [ShelfItem]
    /// Whether this is the tile for all the files, rather than one of them.
    var isAll = false
    let image: NSImage
    /// Where the tile shows the image, in the tile's coordinates with the origin at the top left.
    let imageFrame: CGRect
    let shelf: Shelf
    let dragSource: ShelfDragSource

    func makeNSView(context: Context) -> ShelfTileMouseView {
        ShelfTileMouseView()
    }

    func updateNSView(_ view: ShelfTileMouseView, context: Context) {
        view.items = items
        view.isAll = isAll
        view.image = image
        view.imageFrame = imageFrame
        view.shelf = shelf
        view.dragSource = dragSource
    }
}

final class ShelfTileMouseView: NSView {
    var items: [ShelfItem] = []
    var isAll = false
    var image: NSImage?
    var imageFrame: CGRect = .zero
    weak var shelf: Shelf?
    weak var dragSource: ShelfDragSource?
    private var mouseDown: NSEvent?

    override var isFlipped: Bool { true }

    // The notch is mostly not key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDown, !items.isEmpty, let image, let dragSource else { return }
        let start = mouseDown.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }

        self.mouseDown = nil
        dragSource.beginDrag(of: items, image: image, frame: Self.fit(image.size, in: imageFrame), event: mouseDown, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDown = nil
        if event.clickCount == 2, !isAll, let item = items.first {
            NSWorkspace.shared.open(item.url)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let urls = items.map(\.url)
        let menu = NSMenu()
        if isAll {
            menu.addItem(ActionMenuItem("AirDrop All…") {
                ShelfSharing.airDrop(urls)
            })
        } else if let item = items.first {
            menu.addItem(ActionMenuItem("Open") {
                NSWorkspace.shared.open(item.url)
            })
            menu.addItem(ActionMenuItem("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            })
            menu.addItem(ActionMenuItem("AirDrop…") {
                ShelfSharing.airDrop(urls)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Remove from Shelf") { [weak shelf] in
                shelf?.remove(item.id)
            })
        }
        menu.addItem(ActionMenuItem("Clear Shelf") { [weak shelf] in
            shelf?.removeAll()
        })
        return menu
    }

    /// The part of `frame` an image of `size` covers when scaled to fit, as SwiftUI draws it.
    private static func fit(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: frame.midX - fitted.width / 2,
            y: frame.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
