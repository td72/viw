import AppKit

/// The key bindings as data: the `?` overlay, Help › Keyboard Shortcuts and `viw -h` all
/// print from here, so there is one list to keep in step with `VimKeyMap`.
enum KeyHelp {
    /// One line of the help: the keys, what they do, and a note for the small print.
    struct Entry {
        /// Ways to do it (`j / k`, `⌃e / ⌃y`), each a list of counterparts (`j`, `k`), each a
        /// sequence of keys pressed one after the other (`g`, `g`). A chord is one key (`⌃f`).
        let groups: [[[String]]]
        /// What to do when it is not a key: "click a link".
        let plain: String?
        let action: String
        let note: String?

        /// `keys`: `|` between the ways, ` / ` between counterparts, a space between the keys
        /// of a sequence — `"g g / G | Home / End"`.
        init(_ keys: String, _ action: String, _ note: String? = nil) {
            groups = keys.components(separatedBy: " | ").map { way in
                way.components(separatedBy: " / ").map { $0.split(separator: " ").map(String.init) }
            }
            plain = nil
            self.action = action
            self.note = note
        }

        init(plain: String, _ action: String, _ note: String? = nil) {
            groups = []
            self.plain = plain
            self.action = action
            self.note = note
        }

        /// The keys on one line, as `viw -h` prints them: `gg / G   Home / End`.
        var keysText: String {
            plain ?? groups.map { $0.map { $0.joined() }.joined(separator: " / ") }.joined(separator: "   ")
        }

        func matches(_ query: String) -> Bool {
            [keysText, action, note ?? ""].contains { $0.lowercased().contains(query) }
        }
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    /// The sections with only the entries that mention `query` (in the keys, the action or
    /// the note); a section whose title matches keeps all of its entries.
    static func filter(_ sections: [Section], _ query: String) -> [Section] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sections }
        return sections.compactMap { s in
            if s.title.lowercased().contains(q) { return s }
            let hits = s.entries.filter { $0.matches(q) }
            return hits.isEmpty ? nil : Section(title: s.title, entries: hits)
        }
    }

    /// Every view.
    static let common: [Section] = [
        Section(title: "Move", entries: [
            Entry("j / k | ⌃e / ⌃y | ↓ / ↑", "Line down / up"),
            Entry("d / u | ⌃d / ⌃u", "Half page down / up"),
            Entry("⌃f / ⌃b | Space / ⇧Space", "Page down / up", "b pages up too"),
            Entry("g g / G | Home / End", "Top / bottom"),
            Entry("50 G", "Go to 50 %"),
            Entry("h / l | 0 / $", "Sideways", "tables: the column cursor"),
            Entry(plain: "5j, 3d, …", "Counts work with every motion"),
        ]),
        Section(title: "Find & copy", entries: [
            Entry("/", "Find", "incremental; Esc goes back"),
            Entry("n / N", "Next / previous match"),
            Entry("y", "Copy the selection", "tables: the cell"),
            Entry("Esc | ⌃[", "Clear count, selection, filter"),
        ]),
        Section(title: "Tabs & window", entries: [
            Entry("g t / g T | Tab / ⇧Tab", "Next / previous tab"),
            Entry("3 g t | ⌘3", "Tab 3", "⌘1 – ⌘8; ⌘9 is the last tab"),
            Entry("o", "Open a file in a new tab"),
            Entry("q", "Close the tab", "the last one leaves the window empty; q again closes it"),
            Entry("r", "Reload", "PDF / images: rotate instead"),
            Entry("+ / -", "Zoom in / out"),
            Entry("=", "Reset the zoom"),
            Entry("? | ⌘/", "This help", "/ filters it; ?, Esc or q closes it"),
        ]),
    ]

    static let text = Section(title: "Text", entries: [
        Entry(plain: "click a link", "Follow the link", "files viw can show open in this tab; others in their app"),
        Entry(plain: "⌘-click a link", "Open it in a new tab"),
        Entry("H / L | ⌃o", "Back / forward", "through the links followed in this tab; 3H: three back; ⌃o goes back"),
        Entry(plain: "swipe → / ←", "Back / forward", "two fingers on the trackpad"),
        Entry("f / F", "Link hints", "type a label to follow the link / to open it in a new tab; Esc cancels"),
        Entry("⌘F", "The system find bar", "same as /"),
    ])

    static let toc = Section(title: "Table of contents", entries: [
        Entry("t", "Show the headings and move into them", "t again closes; remembered"),
        Entry("] ] / [ [", "Next / previous heading", "without the pane; 3]]: three on"),
        Entry("Enter | i", "Into the pane"),
        Entry(".", "Show / hide the pane"),
        Entry("I", "Pane on the right / at the bottom"),
    ])

    static let tocPane = Section(title: "In the contents pane", entries: [
        Entry("j / k", "Move"),
        Entry("Enter", "Go to the heading"),
        Entry("h / l", "Fold / unfold"),
        Entry("z R / z M", "Unfold / fold all"),
        Entry("/", "Filter the headings"),
        Entry("Esc", "Back to the text"),
    ])

    static let table = Section(title: "Table", entries: [
        Entry("h / l | 0 / $", "Column cursor", "the cell y copies and s sorts by"),
        Entry("f", "Filter rows", "Enter keeps the filter, Esc clears it"),
        Entry("s / S", "Sort by the cursor column / file order", "s again: reverse"),
        Entry(plain: "click a header", "Sort by that column"),
        Entry("y / Y / C", "Copy the cell / row / column", "the row as TSV; the column one cell per line"),
        Entry("v / V / ⌃v", "Visual mode: cells / rows / columns", "select with the movement keys; Esc leaves"),
        Entry("Enter | i", "Into the detail pane"),
        Entry(".", "Show / hide the pane"),
        Entry("I", "Pane on the right / at the bottom"),
    ])

    static let tableVisual = Section(title: "In visual mode", entries: [
        Entry("y", "Copy as TSV"),
        Entry("Y", "Copy as TSV with the header row"),
        Entry("m", "Copy as a Markdown table"),
        Entry("C", "Copy the selected columns in full"),
    ])

    static let tablePane = Section(title: "In the detail pane", entries: [
        Entry("j / k", "Next / previous field"),
        Entry("h / l", "Next / previous row"),
        Entry("s", "Sort by the field"),
        Entry("y", "Copy the field"),
        Entry("Esc", "Back to the grid"),
    ])

    static let json = Section(title: "JSON / JSON Lines", entries: [
        Entry("j / k | g g / G", "Move through the tree"),
        Entry("h / l", "Fold / unfold", "h on a folded value goes to its parent; l on an open one steps in"),
        Entry("Enter | Space | z a", "Fold or unfold", "Space does not page here: ⌃f / ⌃b do"),
        Entry("z o / z c", "Unfold / fold"),
        Entry("e / c", "Unfold / fold with everything inside"),
        Entry("z R / z M", "Unfold / fold the whole tree", "2zR: two levels open, the rest folded"),
        Entry("J / K", "Next / previous sibling", "past whatever is open; 3J: three on"),
        Entry("/", "Find in keys and values", "n / N: next / previous match"),
        Entry("y / Y", "Copy the value / its jq path", "a string's text, an object or array as JSON; .items[2].id"),
        Entry("t", "The array of objects here as a table", "sort, filter, visual mode; t again: back to the tree"),
        Entry("p", "Pretty-printed text ⇄ the tree"),
        Entry(".", "Show / hide the pane", "the value in full"),
        Entry("I", "Pane on the right / at the bottom"),
    ])

    /// JSON while it is shown as text or as a table.
    static let jsonViews = Section(title: "JSON", entries: [
        Entry("p", "Pretty-printed text ⇄ the tree"),
        Entry("t", "Table ⇄ the tree"),
    ])

    static let archive = Section(title: "Zip", entries: [
        Entry("j / k | g g / G", "Move through the tree"),
        Entry("h / l", "Fold / unfold", "or go to the parent / step in"),
        Entry("Enter", "Open the file in a new tab", "extracted to a temporary folder; folders fold / unfold"),
        Entry("/", "Find an entry by path", "n / N: next / previous match"),
        Entry("y", "Copy the entry's path"),
        Entry(".", "Show / hide the pane", "details, the start of a text entry"),
        Entry("I", "Pane on the right / at the bottom"),
    ])

    static let sheets = Section(title: "Sheets / tables", entries: [
        Entry("] / [ | ⌘] / ⌘[", "Next / previous sheet or table", "3]: three ahead; wraps"),
        Entry(plain: "click a sheet", "Show it", "in the bar under the grid"),
    ])

    static let pdf = Section(title: "PDF", entries: [
        Entry("p", "Page view ⇄ continuous scrolling", "page view: one page at a time"),
        Entry("t", "Page overview", "h / j / k / l move, Enter or i opens the page, Esc goes back"),
        Entry("g g / G", "First / last page"),
        Entry("50 G", "The page at 50 %"),
        Entry("r / R", "Rotate clockwise / counter-clockwise"),
        Entry("+ / -", "Zoom in / out"),
        Entry("=", "Fit to width"),
        Entry("/", "Find", "every hit is highlighted; n / N step through them"),
    ])

    static let image = Section(title: "Image", entries: [
        Entry("r / R", "Rotate clockwise / counter-clockwise"),
        Entry("+ / -", "Zoom in / out"),
        Entry("=", "Fit to the window"),
        Entry("y", "Copy the image", "animated: the frame shown"),
        Entry("Space", "Pause / play", "animated GIF / WebP / PNG"),
        Entry("n / N", "Next / previous frame", "animated; pauses"),
    ])

    static let diagram = Section(title: "draw.io", entries: [
        Entry("] / [ | ⌘] / ⌘[", "Next / previous page", "3]: three ahead; wraps"),
    ])

    static let media = Section(title: "Video / audio", entries: [
        Entry("Space", "Play / pause", "at the end: from the top"),
        Entry("j / k", "Seek 5 s"),
        Entry("d / u", "Seek 30 s"),
        Entry("⌃f / ⌃b", "Seek 1 min"),
        Entry("h / l", "One frame back / on", "pauses"),
        Entry("0 / $ | g g / G", "Start / end"),
        Entry("50 G", "The middle"),
        Entry("+ / -", "Volume"),
        Entry("=", "Volume 100 %"),
        Entry("m", "Mute"),
        Entry("r / R", "Rotate the video"),
        Entry("y", "Copy the file"),
    ])

    /// Every section there is, for `viw -h`.
    static let all: [Section] = common + [text, toc, tocPane, json, jsonViews, table, tableVisual, tablePane, sheets, archive, pdf, image, diagram, media]

    /// `viw -h`.
    static func plainText(_ sections: [Section]) -> String {
        var out = ""
        for s in sections {
            out += "  \(s.title)\n"
            let w = s.entries.map { $0.keysText.count }.max() ?? 0
            for e in s.entries {
                out += "    " + e.keysText.padding(toLength: w + 3, withPad: " ", startingAt: 0) + e.action + (e.note.map { " (\($0))" } ?? "") + "\n"
            }
            out += "\n"
        }
        return out
    }
}

/// The `?` overlay: dims the content and shows the keys in a centered card — the current
/// view's own first, then the common ones — as key caps in one to three columns, scrolling
/// when the window is too small for them. `/` filters; `?`, Esc, `q`, Enter or a click
/// outside closes it.
final class HelpOverlay: NSView {
    var onClose: (() -> Void)?
    private let card = CardView()
    private let header = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let rule = NSBox()
    private let scroll = NSScrollView()
    private let content = HelpContentView()
    private let blocks: [HelpContentView.Block]
    /// nil: no filter. While `typing`, keys go into it.
    private var query: String?
    private var typing = false
    private var pendingG = false

    private static let pad: CGFloat = 24
    private static let headerHeight: CGFloat = 46
    private static let columnWidth: CGFloat = 420
    private static let columnGap: CGFloat = 36

    init(title: String, sections: [KeyHelp.Section], viewSections: [KeyHelp.Section]) {
        blocks = viewSections.map { .init(section: $0, own: true) } + sections.map { .init(section: $0, own: false) }
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        card.wantsLayer = true
        card.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -8)
            return s
        }()
        addSubview(card)

        header.stringValue = title
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .right
        rule.boxType = .separator
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        for v in [header, hint, rule, scroll] as [NSView] { card.addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        arrange()
    }

    /// Size the card for all the keys (so it does not jump while a filter narrows them down),
    /// then lay out what the filter leaves.
    private func arrange() {
        let pad = Self.pad
        let availableWidth = max(240, bounds.width - 48 - pad * 2)
        let availableHeight = max(120, bounds.height - 64 - Self.headerHeight - pad)
        let columnWidth = min(Self.columnWidth, availableWidth)
        let most = max(1, min(3, Int((availableWidth + Self.columnGap) / (columnWidth + Self.columnGap))))
        // As few columns as show everything without scrolling; all that fit when nothing does.
        var columns = 1
        var full = content.arrange(blocks, columns: 1, columnWidth: columnWidth, gap: Self.columnGap)
        while full.height > availableHeight, columns < most {
            columns += 1
            full = content.arrange(blocks, columns: columns, columnWidth: columnWidth, gap: Self.columnGap)
        }
        let shown: [HelpContentView.Block]
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            shown = blocks.compactMap { b in
                KeyHelp.filter([b.section], query).first.map { .init(section: $0, own: b.own) }
            }
        } else {
            shown = blocks
        }
        content.emptyMessage = shown.isEmpty ? "No key matches “\(query ?? "")”" : nil
        let size = content.arrange(shown, columns: columns, columnWidth: columnWidth, gap: Self.columnGap)

        let bodyHeight = min(full.height, availableHeight)
        let width = full.width + pad * 2
        let height = Self.headerHeight + bodyHeight + pad
        card.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        header.frame = NSRect(x: pad, y: height - 33, width: width * 0.55 - pad, height: 20)
        hint.frame = NSRect(x: width * 0.55, y: height - 31, width: width * 0.45 - pad, height: 16)
        rule.frame = NSRect(x: 0, y: height - Self.headerHeight, width: width, height: 1)
        // Wider than the text by most of the right padding, so the scroller has room beside it.
        scroll.frame = NSRect(x: pad, y: pad / 2, width: full.width + pad - 4, height: bodyHeight + pad / 2 - 12)
        content.frame = NSRect(x: 0, y: 0, width: full.width, height: max(size.height, scroll.contentSize.height))
        content.needsDisplay = true
        updateHint()
    }

    private func updateHint() {
        if let query {
            hint.stringValue = typing ? "/\(query)▏   Enter keeps · Esc clears" : "/\(query)   Esc clears the filter"
            hint.textColor = .controlAccentColor
        } else {
            hint.stringValue = "/ filter   ·   ? Esc q close"
            hint.textColor = .tertiaryLabelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
    }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        if typing { return type(event, chars, flags) }
        defer { if chars != "g" { pendingG = false } }
        let page = scroll.contentSize.height
        if flags.contains(.control) {
            switch chars {
            case "d": scrollBy(page / 2)
            case "u": scrollBy(-page / 2)
            case "f": scrollBy(page - 40)
            case "b": scrollBy(40 - page)
            case "e": scrollBy(40)
            case "y": scrollBy(-40)
            case "[": escape()
            default: break
            }
            return
        }
        if let key = event.specialKey {
            switch key {
            case .downArrow: scrollBy(40)
            case .upArrow: scrollBy(-40)
            case .pageDown: scrollBy(page - 40)
            case .pageUp: scrollBy(40 - page)
            case .home: scrollTo(0)
            case .end: scrollTo(.greatestFiniteMagnitude)
            case .carriageReturn, .enter: onClose?()
            default: break
            }
            return
        }
        switch chars {
        case "/":
            typing = true
            query = query ?? ""
            updateHint()
        case "j": scrollBy(40)
        case "k": scrollBy(-40)
        case "d": scrollBy(page / 2)
        case "u": scrollBy(-page / 2)
        case " ": scrollBy(flags.contains(.shift) ? 40 - page : page - 40)
        case "b": scrollBy(40 - page)
        case "g": if pendingG { scrollTo(0); pendingG = false } else { pendingG = true }
        case "G": scrollTo(.greatestFiniteMagnitude)
        case "?", "q": onClose?()
        case "\u{1B}": escape()
        default: break // swallow: the document must not scroll under the card
        }
    }

    /// A key while the filter is being typed.
    private func type(_ event: NSEvent, _ chars: String, _ flags: NSEvent.ModifierFlags) {
        if chars == "\u{1B}" || (flags.contains(.control) && chars == "[") {
            typing = false
            query = nil
        } else if event.specialKey == .carriageReturn || event.specialKey == .enter {
            typing = false
            if query?.isEmpty ?? true { query = nil }
        } else if event.specialKey == .delete || event.specialKey == .backspace {
            if !(query ?? "").isEmpty { query?.removeLast() }
        } else if !flags.contains(.command), !flags.contains(.control), event.specialKey == nil, let typed = event.characters, !typed.isEmpty {
            query = (query ?? "") + typed
        } else {
            return
        }
        arrange()
        scrollTo(0)
    }

    /// Esc: drop the filter first, then close.
    private func escape() {
        if query != nil {
            query = nil
            arrange()
        } else {
            onClose?()
        }
    }

    private func scrollBy(_ dy: CGFloat) { scrollTo(scroll.contentView.bounds.origin.y + dy) }

    private func scrollTo(_ y: CGFloat) {
        let limit = max(0, content.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, limit))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func cancelOperation(_ sender: Any?) { escape() }
    override func mouseDown(with event: NSEvent) { onClose?() }

    /// Opaque rounded card, so the dimmed content underneath does not show through the text.
    private final class CardView: NSView {
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor.controlBackgroundColor.setFill() // white (near-black in dark mode): a dialog, not a dimmed panel
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        override func mouseDown(with event: NSEvent) {} // clicks on the card keep it open
    }
}

/// The body of the help card: sections in columns, each entry a row of key caps with what
/// they do beside them and the small print under that. Everything is drawn here; `arrange`
/// works out where.
final class HelpContentView: NSView {
    struct Block {
        let section: KeyHelp.Section
        /// One of the current view's own sections: its title stands out.
        let own: Bool
    }

    private enum Item {
        case title(NSRect, String, own: Bool)
        case rule(NSRect)
        case cap(NSRect, String)
        case mark(NSPoint, String)          // "/" between counterparts, "·" between ways
        case text(NSRect, NSAttributedString) // the action, the note, a plain "click a link"
    }

    private var items: [Item] = []
    var emptyMessage: String?

    override var isFlipped: Bool { true }

    private static let capFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let capHeight: CGFloat = 20
    private static let actionFont = NSFont.systemFont(ofSize: 12.5)
    private static let noteFont = NSFont.systemFont(ofSize: 11)
    private static let titleFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    private static let markFont = NSFont.systemFont(ofSize: 11)
    private static let keysWidthLimit: CGFloat = 180

    private static func capWidth(_ key: String) -> CGFloat {
        max(capHeight, ((key as NSString).size(withAttributes: [.font: capFont]).width + 11).rounded(.up))
    }

    /// The keys of an entry flowed into `width`: one line when they fit, a new line per way
    /// when they do not. Returns what to draw (relative to the row's top left) and the size.
    private static func flow(_ entry: KeyHelp.Entry, width: CGFloat) -> (items: [Item], size: NSSize) {
        if let plain = entry.plain {
            let s = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12).italic, .foregroundColor: NSColor.secondaryLabelColor])
            let h = s.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
            return ([.text(NSRect(x: 0, y: 2, width: width, height: h), s)], NSSize(width: min(width, s.size().width.rounded(.up)), height: max(capHeight, h + 2)))
        }
        var items: [Item] = []
        var x: CGFloat = 0, y: CGFloat = 0, widest: CGFloat = 0
        for (g, way) in entry.groups.enumerated() {
            var wayWidth: CGFloat = 0
            for (c, sequence) in way.enumerated() {
                wayWidth += sequence.map(capWidth).reduce(0, +) + CGFloat(sequence.count - 1) * 2 + (c > 0 ? 13 : 0)
            }
            if g > 0 {
                if x + 15 + wayWidth > width { // the next way does not fit: its own line
                    x = 0
                    y += capHeight + 4
                } else {
                    items.append(.mark(NSPoint(x: x + 5, y: y + 3), "·"))
                    x += 15
                }
            }
            for (c, sequence) in way.enumerated() {
                if c > 0 {
                    items.append(.mark(NSPoint(x: x + 4, y: y + 3), "/"))
                    x += 13
                }
                for key in sequence {
                    let w = capWidth(key)
                    items.append(.cap(NSRect(x: x, y: y, width: w, height: capHeight), key))
                    x += w + 2
                }
                x -= 2
            }
            widest = max(widest, x)
        }
        return (items, NSSize(width: widest, height: y + capHeight))
    }

    /// Work out where everything goes and return the size it takes. Sections keep their
    /// order and fill the columns evenly.
    @discardableResult
    func arrange(_ blocks: [Block], columns: Int, columnWidth: CGFloat, gap: CGFloat) -> NSSize {
        items = []
        let entries = blocks.flatMap(\.section.entries)
        let natural = entries.map { Self.flow($0, width: .greatestFiniteMagnitude).size.width }.max() ?? 0
        let keysWidth = min(Self.keysWidthLimit, natural, columnWidth * 0.5)
        let textX = keysWidth + 14
        let textWidth = max(60, columnWidth - textX)

        // Each section laid out at x = 0, y = 0; then placed in its column.
        let laid: [(items: [Item], height: CGFloat)] = blocks.map { block in
            var out: [Item] = [.title(NSRect(x: 0, y: 0, width: columnWidth, height: 14), block.section.title.uppercased(), own: block.own),
                               .rule(NSRect(x: 0, y: 19, width: columnWidth, height: 1))]
            var y: CGFloat = 29
            for e in block.section.entries {
                let keys = Self.flow(e, width: keysWidth)
                out += keys.items.map { Self.offset($0, x: 0, y: y) }
                let action = NSAttributedString(string: e.action, attributes: [.font: Self.actionFont, .foregroundColor: NSColor.labelColor])
                var textHeight = action.boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
                out.append(.text(NSRect(x: textX, y: y + 2, width: textWidth, height: textHeight), action))
                if let note = e.note {
                    let n = NSAttributedString(string: note, attributes: [.font: Self.noteFont, .foregroundColor: NSColor.secondaryLabelColor])
                    let h = n.boundingRect(with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin]).height.rounded(.up)
                    out.append(.text(NSRect(x: textX, y: y + 2 + textHeight + 1, width: textWidth, height: h), n))
                    textHeight += h + 1
                }
                y += max(keys.size.height, textHeight + 2) + 9
            }
            return (out, y - 9)
        }

        let sectionGap: CGFloat = 22
        let total = laid.map(\.height).reduce(0, +) + sectionGap * CGFloat(max(0, laid.count - 1))
        let target = total / CGFloat(max(1, columns))
        var column = 0
        var y: CGFloat = 0
        var tallest: CGFloat = 0
        for section in laid {
            // Start the next column when this section would mostly hang below the target.
            if y > 0, column < columns - 1, y + section.height / 2 > target {
                column += 1
                y = 0
            }
            let x = CGFloat(column) * (columnWidth + gap)
            items += section.items.map { Self.offset($0, x: x, y: y) }
            y += section.height
            tallest = max(tallest, y)
            y += sectionGap
        }
        return NSSize(width: CGFloat(columns) * columnWidth + CGFloat(columns - 1) * gap, height: tallest)
    }

    private static func offset(_ item: Item, x: CGFloat, y: CGFloat) -> Item {
        switch item {
        case .title(let r, let s, let own): return .title(r.offsetBy(dx: x, dy: y), s, own: own)
        case .rule(let r): return .rule(r.offsetBy(dx: x, dy: y))
        case .cap(let r, let s): return .cap(r.offsetBy(dx: x, dy: y), s)
        case .mark(let p, let s): return .mark(NSPoint(x: p.x + x, y: p.y + y), s)
        case .text(let r, let s): return .text(r.offsetBy(dx: x, dy: y), s)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let emptyMessage {
            let s = NSAttributedString(string: emptyMessage, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            s.draw(at: NSPoint(x: ((bounds.width - s.size().width) / 2).rounded(), y: 24))
            return
        }
        for item in items {
            switch item {
            case .title(let r, let s, let own):
                guard r.intersects(dirtyRect) else { continue }
                (s as NSString).draw(at: r.origin, withAttributes: [.font: Self.titleFont, .kern: 0.7,
                                                                   .foregroundColor: own ? NSColor.controlAccentColor : NSColor.secondaryLabelColor])
            case .rule(let r):
                NSColor.separatorColor.setFill()
                r.fill()
            case .cap(let r, let s):
                guard r.intersects(dirtyRect) else { continue }
                // A key cap: a soft face, a hairline around it and a heavier bottom edge.
                let face = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                face.fill()
                NSColor.labelColor.withAlphaComponent(0.22).setStroke()
                face.lineWidth = 1
                face.stroke()
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSRect(x: r.minX + 3, y: r.maxY - 1.5, width: r.width - 6, height: 1).fill()
                let size = (s as NSString).size(withAttributes: [.font: Self.capFont])
                (s as NSString).draw(at: NSPoint(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded() - 0.5),
                                     withAttributes: [.font: Self.capFont, .foregroundColor: NSColor.labelColor])
            case .mark(let p, let s):
                (s as NSString).draw(at: p, withAttributes: [.font: Self.markFont, .foregroundColor: NSColor.tertiaryLabelColor])
            case .text(let r, let s):
                guard r.intersects(dirtyRect) else { continue }
                s.draw(with: r, options: [.usesLineFragmentOrigin])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {} // a click on the card keeps it open
}

private extension NSFont {
    var italic: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask) }
}
