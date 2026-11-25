import AppKit

/// What the renderer attaches to a heading's text (`.viwHeading`). The table of contents is
/// read back from these marks, so it stays right when the text moves under it (a diagram
/// replacing its code block).
final class HeadingMark {
    let level: Int
    let title: String

    init(level: Int, title: String) {
        self.level = level
        self.title = title
    }
}

extension NSAttributedString.Key {
    static let viwHeading = NSAttributedString.Key("viw.heading")
}

/// One heading in the table of contents: a node of the tree the levels make.
final class TOCHeading {
    let mark: HeadingMark
    /// The anchor a `#link` uses for it, GitHub style; unique within the document.
    let slug: String
    private(set) var children: [TOCHeading] = []
    private(set) weak var parent: TOCHeading?

    var level: Int { mark.level }
    var title: String { mark.title }

    fileprivate init(mark: HeadingMark, slug: String) {
        self.mark = mark
        self.slug = slug
    }

    fileprivate func add(_ child: TOCHeading) {
        child.parent = self
        children.append(child)
    }
}

enum TOC {
    /// The headings in document order, linked into a tree: each one hangs under the nearest
    /// heading before it with a lower level (`###` straight under `#` included).
    static func build(_ marks: [HeadingMark]) -> (all: [TOCHeading], roots: [TOCHeading]) {
        var all: [TOCHeading] = []
        var roots: [TOCHeading] = []
        var open: [TOCHeading] = []
        var used: [String: Int] = [:]
        for mark in marks {
            let base = slug(mark.title)
            let n = used[base, default: 0]
            used[base] = n + 1
            let h = TOCHeading(mark: mark, slug: n == 0 ? base : "\(base)-\(n)")
            while let last = open.last, last.level >= h.level { open.removeLast() }
            if let parent = open.last { parent.add(h) } else { roots.append(h) }
            open.append(h)
            all.append(h)
        }
        return (all, roots)
    }

    /// GitHub's anchor for a heading: lowercase, punctuation dropped, spaces to hyphens.
    static func slug(_ title: String) -> String {
        var out = ""
        for u in title.lowercased().unicodeScalars {
            if u == " " { out += "-" }
            else if u == "-" || u == "_" || u.properties.isAlphabetic || u.properties.numericType != nil { out.unicodeScalars.append(u) }
        }
        return out
    }

    /// The heading a `#fragment` means: its slug, or failing that the same words whatever
    /// the punctuation (links written by hand are often a little off).
    static func heading(for fragment: String, in all: [TOCHeading]) -> TOCHeading? {
        let wanted = fragment.lowercased()
        if let exact = all.first(where: { $0.slug == wanted }) { return exact }
        func loose(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let words = loose(fragment)
        return all.first { loose($0.title) == words }
    }
}

/// The table of contents beside a text document: the headings as a tree (NSOutlineView).
/// It only shows and selects; `TextDocumentView` owns it, feeds it the vim keys and jumps.
final class TOCPane: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let view = NSBox()
    let outline = VimOutlineView()
    private let title = NSTextField(labelWithString: "CONTENTS")
    private let rule = NSBox()
    private let edge = NSBox() // the line between the text and the pane
    private let scroll = NSScrollView()
    private let field = NSSearchField()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))

    private var all: [TOCHeading] = []
    private var roots: [TOCHeading] = []
    /// While a filter is on: the matching headings as a flat list.
    private var filtered: [TOCHeading]?
    /// Slugs of the headings the reader folded; survives a reload of the file.
    private var collapsed: Set<String> = []
    private var applying = false

    var font = NSFont.systemFont(ofSize: 13) { didSet { outline.rowHeight = (font.pointSize * 1.7).rounded() } }
    /// Right of the text (the edge line on the left) or below it (on top).
    var onRight = true
    /// Enter or a double click on a heading.
    var onPick: ((TOCHeading) -> Void)?

    private static let titleHeight: CGFloat = 30
    private static let fieldHeight: CGFloat = 30

    override init() {
        super.init()
        view.boxType = .custom
        view.borderWidth = 0
        view.cornerRadius = 0
        view.contentViewMargins = .zero
        view.fillColor = .controlBackgroundColor
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        rule.boxType = .separator
        edge.boxType = .separator

        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 12
        outline.focusRingType = .none
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.target = self
        outline.doubleAction = #selector(picked)
        outline.onFocusChange = { [weak self] focused in self?.title.textColor = focused ? .controlAccentColor : .secondaryLabelColor }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        field.placeholderString = "Filter headings (Enter: keep, Esc: clear)"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.delegate = self
        field.isHidden = true
        for v in [title, rule, scroll, field, edge] as [NSView] { view.contentView?.addSubview(v) }
    }

    /// Place the parts; the owner calls it after giving `view` its frame.
    func layout() {
        let b = view.contentView?.bounds ?? .zero
        let top = Self.titleHeight + (field.isHidden ? 0 : Self.fieldHeight)
        title.frame = NSRect(x: 14, y: b.height - Self.titleHeight + 8, width: max(0, b.width - 28), height: 16)
        rule.frame = NSRect(x: 0, y: b.height - Self.titleHeight, width: b.width, height: 1)
        field.frame = NSRect(x: 8, y: b.height - top + 4, width: max(0, b.width - 16), height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - top))
        edge.frame = onRight ? NSRect(x: 0, y: 0, width: 1, height: b.height) : NSRect(x: 0, y: b.height - 1, width: b.width, height: 1)
    }

    // MARK: - Content

    func set(all: [TOCHeading], roots: [TOCHeading]) {
        self.all = all
        self.roots = roots
        collapsed.formIntersection(all.map(\.slug))
        filtered = nil
        field.stringValue = ""
        if !field.isHidden { field.isHidden = true; layout() }
        outline.reloadData()
        applyExpansion()
    }

    /// Everything open except what the reader folded. NSOutlineView ignores `expandItem`
    /// before it is in a window, so the owner calls this again when the pane comes up.
    func applyExpansion() {
        guard filtered == nil else { return }
        applying = true
        outline.expandItem(nil, expandChildren: true)
        for h in all where collapsed.contains(h.slug) { outline.collapseItem(h) }
        applying = false
    }

    var selected: TOCHeading? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? TOCHeading : nil
    }

    /// Mark the section being read: its row, or the nearest ancestor on show while it is
    /// folded away (nothing while a filter leaves it out).
    func show(current heading: TOCHeading?) {
        var h = heading
        while let x = h, outline.row(forItem: x) < 0 { h = filtered == nil ? x.parent : nil }
        let row = h.map { outline.row(forItem: $0) } ?? -1
        guard row != outline.selectedRow else { return }
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let filtered { return item == nil ? filtered.count : 0 }
        return (item as? TOCHeading)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let filtered { return filtered[index] }
        return (item as? TOCHeading)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        filtered == nil && !((item as? TOCHeading)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let h = item as? TOCHeading else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.maximumNumberOfLines = 1
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = h.title
        cell.textField?.toolTip = h.title
        cell.textField?.font = h.level == 1 ? .systemFont(ofSize: font.pointSize, weight: .semibold) : font
        cell.textField?.textColor = h.level >= 4 ? .secondaryLabelColor : .labelColor
        return cell
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applying, let h = notification.userInfo?["NSObject"] as? TOCHeading else { return }
        collapsed.insert(h.slug)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !applying, let h = notification.userInfo?["NSObject"] as? TOCHeading else { return }
        collapsed.remove(h.slug)
    }

    @objc private func picked() {
        if let h = selected { onPick?(h) }
    }

    // MARK: - Keys (fed by the owner)

    func move(by n: Int) {
        let count = outline.numberOfRows
        guard count > 0 else { return }
        let row = max(0, min(count - 1, (outline.selectedRow < 0 ? -1 : outline.selectedRow) + n))
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    var rowsPerPage: Int { max(1, Int(scroll.contentSize.height / max(1, outline.rowHeight))) }
    var rowCount: Int { outline.numberOfRows }

    func select(row: Int) {
        guard outline.numberOfRows > 0 else { return }
        let r = max(0, min(outline.numberOfRows - 1, row))
        outline.selectRowIndexes([r], byExtendingSelection: false)
        outline.scrollRowToVisible(r)
    }

    /// `h`: fold the heading, or go up to its parent; `l`: unfold, or step into it.
    func sideways(_ n: Int) {
        guard let h = selected else { return }
        let foldable = filtered == nil && !h.children.isEmpty
        if n < 0 {
            if foldable, outline.isItemExpanded(h) {
                outline.collapseItem(h)
            } else if let parent = h.parent, outline.row(forItem: parent) >= 0 {
                select(row: outline.row(forItem: parent))
            }
        } else if foldable {
            if !outline.isItemExpanded(h) { outline.expandItem(h) } else { move(by: 1) }
        }
    }

    func fold(_ action: FoldAction) {
        guard filtered == nil else { return }
        let h = selected
        switch action {
        case .toggle: if let h, !h.children.isEmpty { if outline.isItemExpanded(h) { outline.collapseItem(h) } else { outline.expandItem(h) } }
        case .open: if let h { outline.expandItem(h) }
        case .close: if let h { outline.collapseItem(h) }
        case .openSubtree: if let h { outline.expandItem(h, expandChildren: true) }
        case .closeSubtree: if let h { outline.collapseItem(h, collapseChildren: true) }
        case .closeAll: outline.collapseItem(nil, collapseChildren: true)
        case .openAll(nil): outline.expandItem(nil, expandChildren: true)
        case .openAll(let depth?):
            outline.collapseItem(nil, collapseChildren: true)
            func open(_ nodes: [TOCHeading], _ levels: Int) {
                guard levels > 0 else { return }
                for n in nodes where !n.children.isEmpty {
                    outline.expandItem(n)
                    open(n.children, levels - 1)
                }
            }
            open(roots, depth)
        }
        // Folding can take the selected row away: its closest ancestor on show gets it.
        var target = h
        while let t = target, outline.row(forItem: t) < 0 { target = t.parent }
        if let target, target !== selected { select(row: outline.row(forItem: target)) }
    }

    // MARK: - Filter (`/`)

    var isFiltering: Bool { filtered != nil || !field.isHidden }

    func beginFilter() {
        field.isHidden = false
        layout()
        view.window?.makeFirstResponder(field)
    }

    func clearFilter() {
        let keep = selected
        filtered = nil
        field.stringValue = ""
        field.isHidden = true
        layout()
        outline.reloadData()
        applyExpansion()
        show(current: keep)
        view.window?.makeFirstResponder(outline)
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = field.stringValue.lowercased()
        filtered = q.isEmpty ? nil : all.filter { $0.title.lowercased().contains(q) }
        outline.reloadData()
        if filtered == nil { applyExpansion() }
        if outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            clearFilter()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Keep the filter and go pick from what is left (an empty one is no filter).
            if filtered == nil { clearFilter() } else { view.window?.makeFirstResponder(outline) }
            return true
        default: return false
        }
    }
}
