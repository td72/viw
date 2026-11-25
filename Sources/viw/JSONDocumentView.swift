import AppKit

/// `DocumentView` for JSON / JSON Lines as a tree, after jless: one row per value, folded
/// containers show a preview of what is inside, and the vim keys move through it — `j` / `k`
/// move, `h` folds (or goes to the parent), `l` unfolds (or steps in), Enter / Space toggle, `/`
/// finds in keys and values, `y` copies the value and `Y` its jq path. The pane shows the
/// selected value in full.
final class JSONDocumentView: NSObject, DocumentView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate {
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let split = UnruledSplitView()
    private let scrollView = NSScrollView()
    private let outline = VimOutlineView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
    private let pane = NSBox()
    private let paneTitle = NSTextField(labelWithString: "")
    private let paneRule = NSBox()
    private let paneEdge = NSBox() // the line between the tree and the pane
    private let paneScroll = NSScrollView()
    private let paneText = NSTextView()
    private let searchBar = NSView()
    private let barLabel = NSTextField(labelWithString: "FIND")
    private let searchField = NSSearchField()

    private var tree: JSONNode?
    private var isLines = false
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var paneEnabled = true
    private var paneSize: CGFloat = 320
    private var matches: [JSONNode] = []
    private var matchIndex = 0
    private var searchOrigin: JSONNode?

    private static let searchBarHeight: CGFloat = 34
    private static let paneTitleHeight: CGFloat = 30
    /// Trees up to this many nodes open fully; bigger ones open folded.
    private static let expandAllLimit = 1500
    /// Longer strings are cut in the tree (the pane and `y` have all of it).
    private static let rowTextLimit = 300
    private static let paneTextLimit = 20_000

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var commands: ViewerCommands? {
        get { outline.commands }
        set { outline.commands = newValue }
    }
    var helpSections: [KeyHelp.Section] { [KeyHelp.json] }

    var status: String? {
        guard let tree else { return nil }
        if isLines { return "\(tree.children.count) \(tree.children.count == 1 ? "record" : "records")" }
        return tree.summary
    }

    /// The rows at the top: the root's members (the root itself only when it is a scalar).
    private var top: [JSONNode] {
        guard let tree else { return [] }
        return tree.isContainer ? tree.children : [tree]
    }

    override init() {
        super.init()
        root.autoresizingMask = [.width, .height]

        searchBar.autoresizingMask = [.width, .minYMargin]
        barLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        barLabel.textColor = .secondaryLabelColor
        barLabel.alignment = .right
        searchBar.addSubview(barLabel)
        searchField.placeholderString = "Find in keys and values (Enter: keep, Esc: back)"
        searchField.delegate = self
        searchBar.addSubview(searchField)
        searchBar.isHidden = true
        root.addSubview(searchBar)

        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 18
        outline.focusRingType = .none
        outline.style = .plain
        outline.backgroundColor = .textBackgroundColor
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        paneTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        paneTitle.textColor = .secondaryLabelColor
        paneTitle.lineBreakMode = .byTruncatingMiddle
        pane.boxType = .custom
        pane.borderWidth = 0
        pane.cornerRadius = 0
        pane.contentViewMargins = .zero
        pane.fillColor = .controlBackgroundColor
        pane.contentView?.addSubview(paneTitle)
        paneRule.boxType = .separator
        pane.contentView?.addSubview(paneRule)
        paneEdge.boxType = .separator
        pane.contentView?.addSubview(paneEdge)
        paneText.isEditable = false
        paneText.isSelectable = true
        paneText.isRichText = true
        paneText.drawsBackground = false
        paneText.textContainerInset = NSSize(width: 14, height: 14)
        paneText.isVerticallyResizable = true
        paneText.isHorizontallyResizable = false
        paneText.autoresizingMask = [.width]
        paneText.textContainer?.widthTracksTextView = true
        paneText.textContainer?.lineFragmentPadding = 0
        paneScroll.documentView = paneText
        paneScroll.hasVerticalScroller = true
        paneScroll.autohidesScrollers = true
        paneScroll.borderType = .noBorder
        paneScroll.drawsBackground = false
        pane.contentView?.addSubview(paneScroll)

        pane.isHidden = true // shown by updatePane once something is selected
        split.delegate = self
        split.dividerStyle = .thin
        split.isVertical = true
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(pane)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        root.addSubview(split)
        layout()
    }

    private func layout() {
        let b = root.bounds
        let top: CGFloat = searchBar.isHidden ? 0 : Self.searchBarHeight
        searchBar.frame = NSRect(x: 0, y: b.height - top, width: b.width, height: top)
        barLabel.frame = NSRect(x: 8, y: 9, width: 48, height: 16)
        searchField.frame = NSRect(x: 64, y: 6, width: b.width - 72, height: 22)
        split.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - top)
        placeHalves()
    }

    /// The tree and the pane inside the split view, as in `ArchiveDocumentView`: the pane keeps
    /// `paneSize` and the tree takes the rest.
    private func placeHalves() {
        let b = split.bounds
        guard !pane.isHidden else { scrollView.frame = b; return }
        let d = split.dividerThickness
        let total = split.isVertical ? b.width : b.height
        let position = max(total * 0.3, total - paneSize).rounded()
        if split.isVertical {
            scrollView.frame = NSRect(x: 0, y: 0, width: position, height: b.height)
            pane.frame = NSRect(x: position + d, y: 0, width: max(0, total - position - d), height: b.height)
        } else {
            scrollView.frame = NSRect(x: 0, y: 0, width: b.width, height: position)
            pane.frame = NSRect(x: 0, y: position + d, width: b.width, height: max(0, total - position - d))
        }
        layoutPane()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { placeHalves() }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !pane.isHidden { // the user dragged the divider
            let current = split.isVertical ? pane.frame.width : pane.frame.height
            if current > 40 { paneSize = current }
        }
        layoutPane()
    }

    private func layoutPane() {
        let b = pane.bounds
        paneTitle.frame = NSRect(x: 14, y: b.height - Self.paneTitleHeight + 8, width: b.width - 28, height: 16)
        paneRule.frame = NSRect(x: 0, y: b.height - Self.paneTitleHeight, width: b.width, height: 1)
        paneScroll.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - Self.paneTitleHeight)
        paneText.frame.size.width = paneScroll.contentSize.width
        paneEdge.frame = split.isVertical ? NSRect(x: 0, y: 0, width: 1, height: b.height) : NSRect(x: 0, y: b.height - 1, width: b.width, height: 1)
    }

    func focus() { root.window?.makeFirstResponder(outline) }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        let size = (theme.baseSize * 0.875).rounded()
        font = theme.codeFont(size: size, weight: .regular)
        outline.rowHeight = (size * 1.6).rounded()
        if split.isVertical != theme.detailPaneOnRight {
            split.isVertical = theme.detailPaneOnRight
            paneSize = theme.detailPaneOnRight ? 320 : 180
            split.adjustSubviews()
        }
        // A reload keeps the selection, what is unfolded and the scroll position.
        let remember = preserveScroll && tree != nil
        let selected = remember ? selectedNode?.steps : nil
        let expanded = remember ? expandedRows.map(\.steps) : nil
        let origin = scrollView.contentView.bounds.origin

        if case .jsonl = kind { isLines = true } else { isLines = false }
        tree = JSONSource.read(source, kind)
        matches = []
        outline.reloadData()
        let show = { [weak self] in
            guard let self, let tree = self.tree else { return }
            if let expanded {
                for steps in expanded { if let n = tree.node(at: steps) { self.outline.expandItem(n) } }
            } else if tree.descendants.count <= Self.expandAllLimit {
                self.outline.expandItem(nil, expandChildren: true)
            }
            if let node = selected.flatMap({ tree.node(at: $0) }), self.outline.row(forItem: node) >= 0 {
                self.select(node, scroll: !remember)
            } else if self.outline.numberOfRows > 0 {
                self.outline.selectRowIndexes([0], byExtendingSelection: false)
            }
            if remember {
                self.scrollView.contentView.scroll(to: origin)
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
            self.updatePane()
            self.layout()
        }
        // The first load happens before the view is in a window, where NSOutlineView ignores expandItem.
        if outline.window != nil { show() } else { DispatchQueue.main.async(execute: show) }
        onStatusChange?()
    }

    /// The unfolded containers among the rows on show (parents before children).
    private var expandedRows: [JSONNode] {
        (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? JSONNode }.filter { outline.isItemExpanded($0) }
    }

    // MARK: - Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? JSONNode)?.children.count ?? top.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? JSONNode)?.children[index] ?? top[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? JSONNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? JSONRowView { return reused }
        let row = JSONRowView()
        row.identifier = id
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? JSONNode else { return nil }
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
            tf.cell?.usesSingleLineMode = true
            tf.cell?.truncatesLastVisibleLine = true
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
        cell.textField?.attributedStringValue = rowText(node)
        return cell
    }

    /// `key: value` in syntax colours; a container shows a preview while folded and its size
    /// while open.
    private func rowText(_ node: JSONNode) -> NSAttributedString {
        let s = NSMutableAttributedString()
        // An attributed string brings its own line breaking: without this the label wraps.
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        func add(_ text: String, _ color: NSColor) {
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: oneLine]))
        }
        switch node.step {
        case .key(let k)?:
            add(JSONNode.keyLabel(k), .labelColor)
            add(": ", .tertiaryLabelColor)
        case .index(let i)?:
            add("\(i): ", .tertiaryLabelColor)
        case nil: break
        }
        switch node.value {
        case .string(let str):
            let cut = str.count > Self.rowTextLimit
            add(JSONNode.quote(cut ? String(str.prefix(Self.rowTextLimit)) : str) + (cut ? "…" : ""), Self.stringColor)
        case .number: add(node.literal, Self.numberColor)
        case .bool: add(node.literal, Self.keywordColor)
        case .null: add("null", .secondaryLabelColor)
        case .invalid(let line):
            add("not JSON  ", .systemRed)
            add(String(line.prefix(Self.rowTextLimit)), .secondaryLabelColor)
        case .object, .array:
            if node.children.isEmpty {
                add(node.value == .object ? "{}" : "[]", .secondaryLabelColor)
            } else if outline.isItemExpanded(node) {
                add(node.value == .object ? "{" : "[", .secondaryLabelColor)
                add("  " + (node.summary ?? ""), .tertiaryLabelColor)
            } else {
                add(node.preview(), .secondaryLabelColor)
                add("  " + (node.summary ?? ""), .tertiaryLabelColor)
            }
        }
        return s
    }

    private static let stringColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.55, green: 0.83, blue: 0.56, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.45, blue: 0.16, alpha: 1) }
    private static let numberColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.47, green: 0.75, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.02, green: 0.31, blue: 0.68, alpha: 1) }
    private static let keywordColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.82, green: 0.66, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.51, green: 0.31, blue: 0.87, alpha: 1) }

    func outlineViewSelectionDidChange(_ notification: Notification) { updatePane() }
    func outlineViewItemDidExpand(_ notification: Notification) { refreshRow(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshRow(notification) }

    /// A container's row reads differently folded and open.
    private func refreshRow(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? JSONNode else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        cell.textField?.attributedStringValue = rowText(node)
    }

    // MARK: - Pane

    private var selectedNode: JSONNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? JSONNode : nil
    }

    private func updatePane() {
        let node = selectedNode
        let show = paneEnabled && node != nil
        if let node, show {
            paneTitle.stringValue = node.path
            paneText.textStorage?.setAttributedString(paneContent(node))
            paneScroll.contentView.scroll(to: .zero)
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        }
        if pane.isHidden == show {
            pane.isHidden = !show
            split.adjustSubviews()
            layout()
        }
    }

    /// The value in full for the pane: a string as the text it holds, anything else as
    /// pretty-printed JSON in the tree's colours; cut off after `paneTextLimit` characters.
    private func paneContent(_ node: JSONNode) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let limit = Self.paneTextLimit
        func add(_ text: String, _ color: NSColor) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        func write(_ n: JSONNode, _ depth: Int) {
            switch n.value {
            case .string: add(n.literal, Self.stringColor)
            case .number: add(n.literal, Self.numberColor)
            case .bool: add(n.literal, Self.keywordColor)
            case .null: add("null", .secondaryLabelColor)
            case .invalid(let line): add(line, .systemRed)
            case .object, .array:
                let (open, close) = n.value == .object ? ("{", "}") : ("[", "]")
                guard !n.children.isEmpty else { add(open + close, .secondaryLabelColor); return }
                add(open, .secondaryLabelColor)
                for (i, c) in n.children.enumerated() {
                    if out.length > limit { return }
                    if i > 0 { add(",", .secondaryLabelColor) }
                    add("\n" + String(repeating: " ", count: (depth + 1) * 2), .labelColor)
                    if case .key(let k)? = c.step {
                        add(JSONNode.quote(k), .labelColor)
                        add(": ", .secondaryLabelColor)
                    }
                    write(c, depth + 1)
                }
                if out.length > limit { return }
                add("\n" + String(repeating: " ", count: depth * 2) + close, .secondaryLabelColor)
            }
        }
        switch node.value {
        case .string(let s), .invalid(let s): add(s.count > limit ? String(s.prefix(limit)) : s, .labelColor)
        default: write(node, 0)
        }
        if out.length > limit { add("\n…", .tertiaryLabelColor) }
        return out
    }

    // MARK: - Navigation (vim keys)

    private func select(_ node: JSONNode, scroll: Bool = true) {
        // The outline only knows items it has loaded, so the chain comes from the tree.
        for a in node.ancestors where a !== tree { outline.expandItem(a) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        if scroll { outline.scrollRowToVisible(row) }
    }

    private func move(by n: Int) {
        let count = outline.numberOfRows
        guard count > 0 else { return }
        let row = max(0, min(count - 1, (outline.selectedRow < 0 ? -1 : outline.selectedRow) + n))
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    private var rowsPerPage: Int { max(1, Int(scrollView.contentSize.height / max(1, outline.rowHeight))) }

    func scrollLines(_ n: Int) { move(by: n) }
    func scrollHalfPages(_ n: Int) { move(by: n * max(1, rowsPerPage / 2)) }
    func scrollPages(_ n: Int) { move(by: n * rowsPerPage) }
    func scrollToTop() { move(by: -outline.numberOfRows) }
    func scrollToBottom() { move(by: outline.numberOfRows) }
    func scrollToPercent(_ percent: Int) {
        guard outline.numberOfRows > 0 else { return }
        let row = (outline.numberOfRows - 1) * max(0, min(100, percent)) / 100
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// `h`: fold the container, or go up to the parent; `l`: unfold, or step into the first child.
    func scrollHorizontal(_ n: Int) {
        guard let node = selectedNode else { return }
        let foldable = !node.children.isEmpty
        if n < 0 {
            if foldable, outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else if let parent = node.parent, parent !== tree {
                select(parent)
            }
        } else if foldable {
            if !outline.isItemExpanded(node) { outline.expandItem(node) } else { move(by: 1) }
        }
    }

    /// Enter / `i`: fold / unfold.
    func switchPane() { fold(.toggle) }

    /// `za` / `zo` / `zc`: this node; `e` / `c`: it and everything inside; `zR` / `zM`: the whole
    /// tree (`2zR`: two levels open). The cursor stays on its node, or on the nearest ancestor
    /// still in sight.
    func fold(_ action: FoldAction) {
        let node = selectedNode
        switch action {
        case .toggle, .open, .close, .openSubtree, .closeSubtree:
            guard let node, !node.children.isEmpty else { return }
            switch action {
            case .toggle: if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            case .open: outline.expandItem(node)
            case .close: outline.collapseItem(node)
            case .openSubtree: outline.expandItem(node, expandChildren: true)
            default: outline.collapseItem(node, collapseChildren: true)
            }
        case .closeAll:
            outline.collapseItem(nil, collapseChildren: true)
        case .openAll(nil):
            outline.expandItem(nil, expandChildren: true)
        case .openAll(let depth?):
            outline.collapseItem(nil, collapseChildren: true)
            func open(_ nodes: [JSONNode], _ levels: Int) {
                guard levels > 0 else { return }
                for n in nodes where !n.children.isEmpty {
                    outline.expandItem(n)
                    open(n.children, levels - 1)
                }
            }
            open(top, depth)
        }
        // Folding can take the cursor's row away: the closest ancestor on show gets it.
        var target = node
        while let t = target, outline.row(forItem: t) < 0 { target = t.parent }
        if let target, target !== selectedNode {
            let row = outline.row(forItem: target)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        if outline.selectedRow >= 0 { outline.scrollRowToVisible(outline.selectedRow) }
    }

    /// `J` / `K`: to the next / previous sibling, past whatever the node has open.
    func moveSibling(_ n: Int) {
        guard let node = selectedNode else { return }
        let siblings = node.parent?.children ?? top
        guard let i = siblings.firstIndex(where: { $0 === node }) else { return }
        select(siblings[max(0, min(siblings.count - 1, i + n))])
    }

    /// Space folds / unfolds too (as in jless), so it never pages here: `⌃f` / `⌃b` do.
    func togglePlayback() -> Bool {
        switchPane()
        return true
    }

    func toggleDetail() {
        paneEnabled.toggle()
        updatePane()
    }

    // MARK: - Find

    func find() {
        searchOrigin = selectedNode
        searchBar.isHidden = false
        layout()
        root.window?.makeFirstResponder(searchField)
    }

    func filter() {}
    func sortRows() {}
    func unsortRows() {}

    func findNext(reverse: Bool) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + (reverse ? -1 : 1)) % matches.count + matches.count) % matches.count
        select(matches[matchIndex])
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue.lowercased()
        matches = q.isEmpty ? [] : (tree?.descendants ?? []).filter { node in
            if case .key(let k)? = node.step, k.lowercased().contains(q) { return true }
            return !node.isContainer && node.copyText.lowercased().contains(q)
        }
        // Start from the first match at or after where the search began.
        let from = searchOrigin.map { outline.row(forItem: $0) } ?? 0
        matchIndex = matches.firstIndex { n in let r = outline.row(forItem: n); return r < 0 || r >= from } ?? 0
        if matches.indices.contains(matchIndex) { select(matches[matchIndex]) } else if let origin = searchOrigin { select(origin) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if let origin = searchOrigin { select(origin) }
            closeSearch()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            closeSearch()
            return true
        default: return false
        }
    }

    private func closeSearch() {
        searchBar.isHidden = true
        layout()
        focus()
    }

    func clearSelection() {
        if !searchBar.isHidden { closeSearch() }
    }

    // MARK: - Copy

    /// `y`: the value — a string's content, a scalar as written, a container as JSON.
    func copySelection() {
        guard let node = selectedNode else { return }
        put(node.copyText, label: node.isContainer ? "Copied \(node.summary ?? "")" : "Copied")
    }

    /// `Y`: the jq path of the value.
    func copyRow() {
        guard let node = selectedNode else { return }
        put(node.path, label: "Copied path")
    }

    private func put(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let anchor = outline.selectedRow >= 0 ? root.convert(outline.rect(ofRow: outline.selectedRow).intersection(outline.visibleRect), from: outline) : nil
        Toast.show(in: root, label, detail: String(text.prefix(400)), near: anchor.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - As a table (`t`)

    /// The array of objects the cursor is on or inside (else the whole document, if it is one).
    var tableCandidate: JSONNode? {
        var n = selectedNode
        while let node = n {
            if node.isTabular { return node }
            n = node.parent
        }
        return tree?.isTabular == true ? tree : nil
    }

    func snapshot(to path: String) {
        guard path != "/dev/null", let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}

/// A split view that draws no divider line. `placeHalves` puts the halves where it wants
/// them, and NSSplitView would still draw its line where it thinks the divider is — across
/// the tree, in a narrow window. The pane draws the edge itself.
private final class UnruledSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

/// A row whose selection is a tint, so the syntax colours stay readable on it.
private final class JSONRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.28 : 0.14).setFill()
        bounds.fill()
    }
}
