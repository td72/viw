import AppKit

/// Link hints (`f` / `F` in a text document, after Vimium): every link in sight gets a short
/// label, and typing the label follows the link without the mouse.
enum LinkHints {
    /// Home row first: the labels are typed with the fingers already there.
    static let alphabet = "asdfghjkl"

    /// `count` labels, all of the same length (the shortest that gives enough of them), so none
    /// is a prefix of another and a label is complete the moment its last letter is typed. The
    /// first letter varies fastest: neighbouring links start with different keys.
    static func labels(count: Int, alphabet: String = LinkHints.alphabet) -> [String] {
        let letters = Array(alphabet)
        guard count > 0, !letters.isEmpty else { return [] }
        guard letters.count > 1 else { return (1...count).map { String(repeating: letters[0], count: $0) } }
        var length = 1
        var capacity = letters.count
        while capacity < count {
            length += 1
            capacity *= letters.count
        }
        return (0..<count).map { index in
            var n = index
            var label = ""
            for _ in 0..<length {
                label.append(letters[n % letters.count])
                n /= letters.count
            }
            return label
        }
    }
}

/// One label, drawn over the start of its link. Black on yellow in both appearances (the
/// Vimium look): it has to stand out from the page, not blend in with it.
final class LinkHintLabel: NSView {
    let label: String
    /// How many leading letters have been typed already (drawn dimmed).
    var typed = 0 { didSet { needsDisplay = true } }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let padding = NSSize(width: 4, height: 1)

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        let text = (label.uppercased() as NSString).size(withAttributes: [.font: Self.font])
        setFrameSize(NSSize(width: ceil(text.width) + Self.padding.width * 2, height: ceil(text.height) + Self.padding.height * 2))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks go through to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 1, green: 0.84, blue: 0.25, alpha: 1).setFill()
        box.fill()
        NSColor(srgbRed: 0.6, green: 0.45, blue: 0, alpha: 1).setStroke()
        box.stroke()
        let text = NSMutableAttributedString(string: label.uppercased(), attributes: [
            .font: Self.font, .foregroundColor: NSColor.black,
        ])
        text.addAttribute(.foregroundColor, value: NSColor(white: 0, alpha: 0.35), range: NSRange(location: 0, length: min(typed, text.length)))
        text.draw(at: NSPoint(x: Self.padding.width, y: Self.padding.height))
    }
}
