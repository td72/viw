import AppKit

/// Read-only NSTextView with vim-style key handling. Mouse/trackpad scrolling
/// is untouched (NSScrollView handles it), as are Cmd-shortcuts (menu bar).
final class VimTextView: NSTextView {
    weak var commands: ViewerCommands?

    /// Readable column: the text container never exceeds this width and is centered.
    var maxContentWidth: CGFloat = 948
    var minInset = NSSize(width: 32, height: 28)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutColumn()
    }

    func relayoutColumn() {
        guard let container = textContainer else { return }
        let available = max(0, bounds.width - minInset.width * 2)
        let width = min(available, maxContentWidth)
        let inset = NSSize(width: ((bounds.width - width) / 2).rounded(.down), height: minInset.height)
        // Inset first (display only), then the width (invalidates layout) followed at once by a
        // full layout pass, so no display request ever finds layout holes to fill — that path is
        // quadratic in TextKit 1 and hangs on ~100k-paragraph documents.
        if textContainerInset != inset { textContainerInset = inset }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager?.ensureLayout(for: container)
        }
    }

    private var keys = VimKeyMap()
    /// Called with true / false as the view gains / loses keyboard focus (the table's detail pane uses it).
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    // MARK: - Swipe back / forward

    /// Two-finger sideways swipes go back / forward through the tab's history (the document
    /// view sets this; the table's detail pane does not). Follows the "Swipe between pages"
    /// trackpad setting, like Safari.
    var swipeNavigates = false
    /// Between a gesture's first event and the first one that moves: its axis is not known yet.
    private var swipeUndecided = false

    override func scrollWheel(with event: NSEvent) {
        guard swipeNavigates, NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return super.scrollWheel(with: event) }
        if event.phase == .began { swipeUndecided = true }
        guard swipeUndecided, event.phase == .began || event.phase == .changed else {
            if event.phase != .changed { swipeUndecided = false } // ended / cancelled / momentum
            return super.scrollWheel(with: event)
        }
        let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
        guard dx > 0 || dy > 0 else { return super.scrollWheel(with: event) } // no direction yet
        swipeUndecided = false
        // Mostly vertical: an ordinary scroll, and it stays one for the rest of the gesture.
        guard dx > dy else { return super.scrollWheel(with: event) }
        event.trackSwipeEvent(options: [], dampenAmountThresholdMin: -1, max: 1) { [weak self] amount, phase, _, _ in
            // `.ended`: the swipe went far enough (a short one is `.cancelled`). Fingers moving
            // right (amount > 0) pull the previous page in, as in Safari.
            guard phase == .ended, let commands = self?.commands else { return }
            if amount > 0 { commands.goBack(1) } else if amount < 0 { commands.goForward(1) }
        }
    }

    // Do not let the find bar's Esc reach `cancelOperation` → beep
    override func cancelOperation(_ sender: Any?) {}
}
