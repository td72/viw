import AppKit
import UniformTypeIdentifiers

/// `DocumentView` for zip archives: the entries as a tree (NSOutlineView) with size and
/// date columns, a pane with the start of the selected text entry, and vim keys — `j` / `k`
/// move, `h` collapses (or goes to the parent), `l` expands (or goes into), Enter opens the
/// file in a new tab or toggles a folder, `/` finds by path, `y` copies the path, `.` hides
/// the pane.
final class ArchiveDocumentView: NSObject, DocumentView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate {
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let split = NSSplitView()
    private let scrollView = NSScrollView()
    private let outline = VimOutlineView()
    private let pane = NSBox()
    private let paneTitle = NSTextField(labelWithString: "")
    private let paneRule = NSBox()
    private let paneScroll = NSScrollView()
    private let paneText = NSTextView()
    private let searchBar = NSView()
    private let barLabel = NSTextField(labelWithString: "FIND")
    private let searchField = NSSearchField()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    private let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))

    private var browser: ArchiveBrowser?
    private var tree = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
    private var error: String?
    private var theme = Theme()
    private var font = NSFont.systemFont(ofSize: 14)
    private var digitFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private var paneEnabled = true
    private var paneSize: CGFloat = 320
    private var matches: [ArchiveNode] = []
    private var matchIndex = 0
    private var searchOrigin: ArchiveNode?

    private static let searchBarHeight: CGFloat = 34
    private static let paneTitleHeight: CGFloat = 30
    /// Trees up to this many nodes open fully; bigger ones open the top level only.
    private static let expandAllLimit = 400

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    var onOpenTab: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var commands: ViewerCommands? {
        get { outline.commands }
        set { outline.commands = newValue }
    }
    var helpSections: [KeyHelp.Section] { [KeyHelp.archive] }

    var status: String? {
        if let error { return error }
        guard let browser else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(browser.entryCount) \(browser.entryCount == 1 ? "entry" : "entries") · \(f.string(fromByteCount: Int64(browser.totalSize)))"
    }

    override init() {
        super.init()
        root.autoresizingMask = [.width, .height]

        searchBar.autoresizingMask = [.width, .minYMargin]
        barLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        barLabel.textColor = .secondaryLabelColor
        barLabel.alignment = .right
        searchBar.addSubview(barLabel)
        searchField.placeholderString = "Find an entry by path (Enter: keep, Esc: back)"
        searchField.delegate = self
        searchBar.addSubview(searchField)
        searchBar.isHidden = true
        root.addSubview(searchBar)

        nameColumn.title = "Name"
        sizeColumn.title = "Size"
        dateColumn.title = "Modified"
        sizeColumn.width = 90
        dateColumn.width = 130
        sizeColumn.resizingMask = []
        dateColumn.resizingMask = []
        nameColumn.resizingMask = .autoresizingMask
        for c in [nameColumn, sizeColumn, dateColumn] { outline.addTableColumn(c) }
        outline.outlineTableColumn = nameColumn
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 16
        outline.focusRingType = .none
        outline.doubleAction = #selector(doubleClicked)
        outline.target = self
        outline.headerView?.isHidden = false
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

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
        split.autoresizingMask = [.width, .height] // the window resizes it; layout() only places the divider on events
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

    /// The tree and the pane inside the split view: the pane keeps `paneSize` (what the user
    /// dragged it to) and the tree takes the rest. NSSplitView's own proportional resizing is
    /// bypassed (it kept collapsing a pane that had started out hidden).
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
    }

    func focus() { root.window?.makeFirstResponder(outline) }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        self.theme = theme
        let size = (theme.baseSize * 0.875).rounded()
        font = .systemFont(ofSize: size)
        digitFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        outline.rowHeight = (size * 1.6).rounded()
        func width(_ sample: String) -> CGFloat { (sample as NSString).size(withAttributes: [.font: digitFont]).width + 16 }
        sizeColumn.width = width("8888 bytes")
        dateColumn.width = width("2026-11-02 15:55")
        if split.isVertical != theme.detailPaneOnRight {
            split.isVertical = theme.detailPaneOnRight
            paneSize = theme.detailPaneOnRight ? 320 : 180
            split.adjustSubviews()
        }
        let remember = preserveScroll && browser != nil // a reload keeps the selection and what is unfolded
        let selectedPath = remember ? selectedNode?.path : nil
        let expanded = remember ? Set(tree.descendants.filter { outline.isItemExpanded($0) }.map(\.path)) : nil

        error = nil
        guard let url = source.url else { fail("Archives can only be opened from a file"); return }
        do {
            let b = try ArchiveBrowser(url: url)
            browser = b
            tree = b.root
        } catch {
            fail("Cannot read \(url.lastPathComponent): \(error)")
            return
        }
        outline.reloadData()
        let toExpand: [ArchiveNode]
        if let expanded {
            toExpand = tree.descendants.filter { expanded.contains($0.path) }
        } else if tree.descendants.count <= Self.expandAllLimit {
            toExpand = tree.descendants.filter(\.isDirectory) // parents come first
        } else {
            toExpand = tree.children.filter(\.isDirectory)
        }
        let selected = selectedPath.flatMap { p in tree.descendants.first { $0.path == p } }
        let show = { [weak self] in
            guard let self else { return }
            for node in toExpand { self.outline.expandItem(node) }
            if let selected {
                self.select(selected)
            } else if self.outline.numberOfRows > 0 {
                self.outline.selectRowIndexes([0], byExtendingSelection: false)
            }
            self.updatePane()
            self.layout()
        }
        // The first load happens before the view is in a window, where NSOutlineView ignores expandItem.
        if outline.window != nil { show() } else { DispatchQueue.main.async(execute: show) }
        onStatusChange?()
    }

    private func fail(_ message: String) {
        browser = nil
        tree = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
        error = message
        outline.reloadData()
        updatePane()
        onStatusChange?()
    }

    // MARK: - Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? ArchiveNode) ?? tree).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? ArchiveNode) ?? tree).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ArchiveNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveNode, let column = tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell-" + column.identifier.rawValue)
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = column === nameColumn ? .byTruncatingMiddle : .byClipping
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            if column === nameColumn {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv)
                cell.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                ])
            } else {
                tf.alignment = column === sizeColumn ? .right : .left
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            }
            NSLayoutConstraint.activate([
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let tf = cell.textField!
        switch column {
        case nameColumn:
            tf.font = font
            tf.stringValue = node.name
            tf.textColor = node.entry?.encrypted == true ? .secondaryLabelColor : .labelColor
            cell.imageView?.image = Self.icon(for: node)
        case sizeColumn:
            tf.font = digitFont
            tf.textColor = .secondaryLabelColor
            tf.stringValue = Self.bytes(node.size)
        default:
            tf.font = digitFont
            tf.textColor = .secondaryLabelColor
            tf.stringValue = node.entry?.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updatePane() }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/" : (node.name as NSString).pathExtension.lowercased()
        if let i = iconCache[key] { return i }
        let type = node.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = n < 1024 ? .useBytes : [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }

    // MARK: - Pane

    private var selectedNode: ArchiveNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? ArchiveNode : nil
    }

    private func updatePane() {
        let node = selectedNode
        let show = paneEnabled && node != nil
        if let node, show {
            paneTitle.stringValue = node.path.uppercased()
            let text = NSMutableAttributedString()
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: NSColor.secondaryLabelColor]
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize * 0.4
            func line(_ key: String, _ value: String) {
                let l = NSMutableAttributedString(string: key + "  ", attributes: keyAttrs)
                l.append(NSAttributedString(string: value + "\n", attributes: valueAttrs))
                l.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: l.length))
                text.append(l)
            }
            if node.isDirectory {
                line("Folder", "\(node.fileCount) \(node.fileCount == 1 ? "file" : "files") · \(Self.bytes(node.size))")
            } else if let e = node.entry {
                line("Size", "\(Self.bytes(e.uncompressedSize)) (\(e.uncompressedSize) bytes)")
                line("Packed", "\(Self.bytes(e.compressedSize))" + (e.uncompressedSize > 0 ? " · \(Int((Double(e.compressedSize) / Double(e.uncompressedSize) * 100).rounded()))%" : ""))
                line("Method", e.encrypted ? "encrypted (cannot be opened)" : e.method == 0 ? "stored" : e.method == 8 ? "deflate" : "method \(e.method)")
                if let m = e.modified { line("Modified", Self.dateFormatter.string(from: m)) }
                if let preview = browser?.preview(node) {
                    text.append(NSAttributedString(string: "\n", attributes: valueAttrs))
                    text.append(NSAttributedString(string: preview, attributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular), .foregroundColor: NSColor.labelColor]))
                } else if !e.encrypted, e.uncompressedSize > 0 {
                    text.append(NSAttributedString(string: "\n(binary)", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
                }
            }
            paneText.textStorage?.setAttributedString(text)
            paneScroll.contentView.scroll(to: .zero)
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        }
        if pane.isHidden == show {
            pane.isHidden = !show
            split.adjustSubviews()
            layout()
        }
    }

    // MARK: - Navigation (vim keys)

    private func select(_ node: ArchiveNode) {
        // The outline only knows items it has loaded, so the chain comes from the tree, not from parent(forItem:).
        for a in node.ancestors { outline.expandItem(a) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
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

    /// `h`: fold the folder, or go up to the parent; `l`: unfold, or step into the first child.
    func scrollHorizontal(_ n: Int) {
        guard let node = selectedNode else { return }
        if n < 0 {
            if node.isDirectory, outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else if let parent = outline.parent(forItem: node) as? ArchiveNode {
                select(parent)
            }
        } else if node.isDirectory {
            if !outline.isItemExpanded(node) { outline.expandItem(node) } else if !node.children.isEmpty { move(by: 1) }
        }
    }

    /// Enter: a folder folds / unfolds, a file opens in a new tab.
    func switchPane() { activate() }

    @objc private func doubleClicked() { activate() }

    private func activate() {
        guard let node = selectedNode, let browser else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        do {
            onOpenTab?(try browser.extract(node))
        } catch {
            Toast.show(in: root, "Cannot open \(node.name)", detail: "\(error)")
        }
    }

    func toggleDetail() {
        paneEnabled.toggle()
        updatePane()
    }

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
        matches = q.isEmpty ? [] : tree.descendants.filter { $0.path.lowercased().contains(q) }
        matchIndex = 0
        if let first = matches.first { select(first) } else if let origin = searchOrigin, q.isEmpty { select(origin) }
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

    /// `y` / `Y`: the entry's path inside the archive.
    func copySelection() {
        guard let node = selectedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
        Toast.show(in: root, "Copied", detail: node.path)
    }

    func copyRow() { copySelection() }

    func snapshot(to path: String) {
        guard path != "/dev/null", let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}

/// The outline view that feeds its keys to the vim key map.
final class VimOutlineView: NSOutlineView {
    weak var commands: ViewerCommands?
    private var keys = VimKeyMap()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }
}
