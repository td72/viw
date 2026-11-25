import AppKit

/// The slide of a swipe back / forward, as in Safari. The navigation has already happened
/// when this is made: `page` is the live destination and `leaving` a picture of the page
/// the swipe started on. Back: the picture slides off to the right, uncovering the page.
/// Forward: the page slides in from the right, over the picture.
final class SwipeTransition {
    private let page: NSView
    private let home: NSRect
    private let picture = NSImageView()
    private let shadow = EdgeShadowView()
    private let back: Bool

    init(leaving image: NSImage?, page: NSView, back: Bool) {
        self.page = page
        self.home = page.frame
        self.back = back
        picture.image = image
        picture.imageScaling = .scaleAxesIndependently
        picture.frame = home
        guard let container = page.superview else { return }
        // Bottom to top — back: page, shadow, picture; forward: picture, shadow, page.
        container.addSubview(picture, positioned: back ? .above : .below, relativeTo: page)
        container.addSubview(shadow, positioned: back ? .below : .above, relativeTo: picture)
        move(to: 0)
    }

    /// `progress`: 0 (still on the page being left) … 1 (arrived).
    func move(to progress: CGFloat) {
        let p = max(0, min(progress, 1))
        let edge = home.minX + (back ? p : 1 - p) * home.width // left edge of whichever slides
        (back ? picture : page).setFrameOrigin(NSPoint(x: edge, y: home.minY))
        shadow.frame = NSRect(x: edge - EdgeShadowView.width, y: home.minY, width: EdgeShadowView.width, height: home.height)
    }

    func end() {
        picture.removeFromSuperview()
        shadow.removeFromSuperview()
        page.frame = home
    }
}

/// The shadow the sliding page casts on the one below, along its left edge.
private final class EdgeShadowView: NSView {
    static let width: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: .clear, ending: NSColor.black.withAlphaComponent(0.22))?.draw(in: bounds, angle: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSView {
    /// What the view shows right now, as an image.
    func snapshotImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
