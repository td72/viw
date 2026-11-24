import AppKit
import Markdown

/// `DocumentView` for everything that is text: Markdown (rendered), source code, JSON and
/// plain files, in an NSTextView (TextKit 1) inside a scroll view. Owns rendering, the
/// asynchronous syntax highlighting, link handling, scrolling, find and the debug snapshot.
final class TextDocumentView: NSObject, DocumentView, NSTextViewDelegate {
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let textView = VimTextView(usingTextLayoutManager: false)
    private var theme = Theme.load()
    /// Bumped on every load so a highlight pass for an older rendering is dropped.
    private var highlightGeneration = 0
    /// While the colors of an asynchronous highlight pass are still to come, diagrams wait in
    /// `deferredPlacements`: the pass addresses the text by position, and a diagram moves it.
    private var highlightPending = false
    private var deferredPlacements: [() -> Void] = []
    /// Diagrams requested from `MermaidRenderer` and not yet answered (the snapshot waits for them).
    private var diagramsPending = 0

    /// Text beyond this (UTF-16 units) is cut off with a notice. TextKit lays the whole
    /// document out before the window shows, and a million paragraphs take tens of seconds.
    static let maxDisplayLength = 1 << 20

    var view: NSView { scrollView }
    var onOpenFile: ((URL) -> Void)?
    var onJump: (() -> Void)?
    /// ⌘-click on a file link / a hint picked with `F`: open it in a new tab instead of replacing this one.
    var onOpenTab: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    /// Receiver of the vim keys typed into the text view.
    var commands: ViewerCommands? {
        get { textView.commands }
        set { textView.commands = newValue }
    }

    override init() {
        super.init()
        buildViews()
    }

    func focus() { scrollView.window?.makeFirstResponder(textView) }
    var helpSections: [KeyHelp.Section] { [KeyHelp.text] }

    // MARK: - Views

    private func buildViews() {
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.findBarPosition = .aboveContent

        let size = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.relayoutColumn()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.displaysLinkToolTips = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = self
        textView.swipeNavigates = true // lines wrap, so a sideways swipe is free for back / forward
        scrollView.documentView = textView

        // Link hints are positioned for what is on screen: anything that moves the text ends them.
        textView.keyInterceptor = { [weak self] event in self?.hintKey(event) ?? false }
        textView.onFocusChange = { [weak self] focused in if !focused { self?.endHints() } }
        textView.onAppearanceChange = { [weak self] in self?.renderDiagrams() }
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewDidMove(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(viewDidMove(_:)), name: NSView.frameDidChangeNotification, object: textView)
    }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        endHints()
        let savedOrigin = scrollView.contentView.bounds.origin
        self.theme = theme
        textView.maxContentWidth = theme.maxWidth
        textView.relayoutColumn()
        var kind = kind
        let (text, baseURL): (String, URL?)
        switch source {
        case .file(let url) where Converted.handles(url):
            // Word / PowerPoint / notebook: converted to Markdown; pictures live in a temporary directory.
            do {
                let r = try Converted.markdown(url: url)
                text = r.markdown
                baseURL = (r.mediaDirectory ?? url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
                kind = .markdown
            } catch {
                show(error: "Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        case .file:
            if case .document = kind {
                loadRich(source: source, preserveScroll: preserveScroll, savedOrigin: savedOrigin)
                return
            }
            let url = source.url!
            guard let data = FileManager.default.contents(atPath: url.path) else {
                show(error: "Cannot read \(url.path)")
                return
            }
            text = String(decoding: data, as: UTF8.self)
            baseURL = url
        case .text(let s, _):
            text = s
            baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/stdin")
        }

        let timing = ProcessInfo.processInfo.environment["VIW_TIMING"] != nil
        var t0 = CFAbsoluteTimeGetCurrent()
        func lap(_ label: String) {
            guard timing else { return }
            let t = CFAbsoluteTimeGetCurrent()
            FileHandle.standardError.write("\(label): \(Int((t - t0) * 1000)) ms\n".data(using: .utf8)!)
            t0 = t
        }

        // Cap what reaches the text system; `truncated` (lines shown / lines total) drives the notice.
        var truncated: (shown: Int, total: Int)?
        func lines(_ s: String) -> Int { s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + 1 }
        func clamp(_ s: String) -> String {
            let ns = s as NSString
            guard ns.length > Self.maxDisplayLength else { return s }
            var cut = Self.maxDisplayLength
            let nl = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cut))
            if nl.location != NSNotFound, nl.location > cut / 2 { cut = nl.location }
            let shown = ns.substring(to: cut)
            truncated = (lines(shown), lines(s))
            return shown
        }

        let renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                        columnWidth: textView.textContainer?.containerSize.width ?? 720, dark: isDark)
        let attributed = NSMutableAttributedString()
        var codeBlocks: [MarkdownRenderer.CodeBlockRef] = []
        switch kind {
        case .markdown:
            let (front, body) = splitFrontMatter(clamp(text))
            if let front {
                attributed.append(renderer.render(Document(parsing: "```yaml\n\(front)\n```\n")))
                codeBlocks += renderer.codeBlocks
            }
            let document = Document(parsing: body)
            lap("parse")
            let offset = attributed.length
            attributed.append(renderer.render(document))
            codeBlocks += renderer.codeBlocks.map { var r = $0; r.range.location += offset; return r }
        case .code(let language):
            attributed.append(renderer.renderCode(clamp(text), language: language))
            codeBlocks = renderer.codeBlocks
        case .json:
            // Format first, cut after, so what is shown keeps its structure. Invalid JSON
            // (or jsonc with comments) is shown as written.
            attributed.append(renderer.renderCode(clamp(JSONPretty.format(text) ?? text), language: "json"))
            codeBlocks = renderer.codeBlocks
        case .jsonl:
            var records: [String] = []
            var shown = 0
            let all = JSONPretty.formatLines(text)
            for r in all {
                if shown + r.utf16.count > Self.maxDisplayLength { break }
                shown += r.utf16.count + 1
                records.append(r)
            }
            if records.count < all.count { truncated = (records.count, all.count) }
            attributed.append(renderer.renderCodeBlocks(records, language: "json", boxed: records.count <= 300))
            codeBlocks = renderer.codeBlocks
        case .plain, .document, .notebook, .presentation, .table, .workbook, .database, .archive, .pdf, .image, .diagram, .video, .audio: // these have their own path / DocumentView; text only if they ever land here
            attributed.append(renderer.renderCode(clamp(text), language: nil))
        }
        if let t = truncated {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let unit: String
            if case .jsonl = kind { unit = "records" } else { unit = "lines" }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = theme.baseSize
            attributed.append(NSAttributedString(
                string: "Showing the first \(f.string(from: t.shown as NSNumber)!) of \(f.string(from: t.total as NSNumber)!) \(unit) — the rest is cut off to keep the viewer responsive.\n",
                attributes: [.font: theme.body, .foregroundColor: theme.secondary, .paragraphStyle: style]))
        }
        lap("render")

        textView.textStorage?.setAttributedString(attributed)
        lap("setAttributedString")
        // Lay everything out now, before the display cycle gets a chance to. TextKit 1 filling
        // layout holes from a display request (setNeedsDisplay, cursor tracking) invalidates the
        // display per line fragment and turns quadratic: ~1 MB of text takes a minute that way
        // and well under a second this way. See also VimTextView.relayoutColumn.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        lap("layout")
        let syncHighlight = ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] != nil
        highlight(codeBlocks, sync: syncHighlight)
        if timing, syncHighlight, !codeBlocks.isEmpty { lap("highlight (sync)") }
        renderDiagrams()

        if preserveScroll, savedOrigin.y > 0 {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scroll(toY: savedOrigin.y)
        }
    }

    /// Word / RTF / OpenDocument: the attributed string NSAttributedString reads, restyled for
    /// the theme (see `RichDocument`). Cut at `maxDisplayLength` like text is.
    private func loadRich(source: Source, preserveScroll: Bool, savedOrigin: NSPoint) {
        guard let url = source.url else { show(error: "Documents can only be opened from a file"); return }
        let rich: NSAttributedString
        do { rich = try RichDocument.read(url: url) } catch {
            show(error: "Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        let attributed = NSMutableAttributedString(attributedString:
            RichDocument.restyle(rich, text: theme.text, scale: theme.baseSize / RichDocument.nominalSize))
        if attributed.length > Self.maxDisplayLength {
            let total = attributed.length
            attributed.deleteCharacters(in: NSRange(location: Self.maxDisplayLength, length: total - Self.maxDisplayLength))
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = theme.baseSize
            attributed.append(NSAttributedString(
                string: "\nShowing the first \(f.string(from: Self.maxDisplayLength as NSNumber)!) of \(f.string(from: total as NSNumber)!) characters — the rest is cut off to keep the viewer responsive.\n",
                attributes: [.font: theme.body, .foregroundColor: theme.secondary, .paragraphStyle: style]))
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        highlight([], sync: true) // no code blocks; bumps the generation so an older highlight pass cannot land
        if preserveScroll, savedOrigin.y > 0 {
            scroll(toY: savedOrigin.y)
        }
    }

    /// Syntax-highlight fenced code blocks. The tree-sitter work (compiling a grammar's query
    /// the first time can take ~100 ms for Swift) runs off the main thread so the document
    /// appears immediately; the colors land a moment later. Only foreground colors change,
    /// so layout and the scroll position are untouched.
    private func highlight(_ blocks: [MarkdownRenderer.CodeBlockRef], sync: Bool) {
        highlightGeneration += 1
        let generation = highlightGeneration
        highlightPending = false
        deferredPlacements = []
        diagramsPending = 0
        guard !blocks.isEmpty else { return }
        let theme = self.theme
        let compute = { () -> [(NSRange, NSColor)] in
            blocks.flatMap { block -> [(NSRange, NSColor)] in
                Highlighter.spans(block.code, info: block.language).compactMap { span in
                    guard let color = theme.codeColor(for: span.name) else { return nil }
                    let r = NSIntersectionRange(
                        NSRange(location: block.range.location + span.range.location, length: span.range.length), block.range)
                    return r.length > 0 ? (r, color) : nil
                }
            }
        }
        let apply = { [weak self] (runs: [(NSRange, NSColor)]) in
            guard let self, generation == self.highlightGeneration, let storage = self.textView.textStorage else { return }
            storage.beginEditing()
            for (range, color) in runs where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
            self.highlightPending = false
            let waiting = self.deferredPlacements
            self.deferredPlacements = []
            waiting.forEach { $0() }
        }
        if sync {
            apply(Highlighter.queue.sync(execute: compute))
        } else {
            highlightPending = true
            Highlighter.queue.async {
                let runs = compute()
                DispatchQueue.main.async { apply(runs) }
            }
        }
    }

    // MARK: - Mermaid diagrams

    private var isDark: Bool { textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Draw every ```mermaid block that does not show its diagram for the current appearance:
    /// the ones still shown as code after a load, all of them after light ⇄ dark. The document
    /// is on screen meanwhile; each diagram lands when it is ready, and a block mermaid cannot
    /// parse stays code.
    private func renderDiagrams() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let dark = isDark
        let generation = highlightGeneration
        var blocks: [MermaidBlock] = []
        storage.enumerateAttribute(MermaidBlock.key, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let block = value as? MermaidBlock, block.shownDark != dark, !blocks.contains(where: { $0 === block }) else { return }
            blocks.append(block)
        }
        for block in blocks {
            diagramsPending += 1
            MermaidRenderer.shared.render(block.request(dark: dark)) { [weak self] outcome in
                guard let self, generation == self.highlightGeneration else { return }
                self.diagramsPending -= 1
                guard case .image(let image) = outcome else {
                    if case .failed(let why) = outcome, ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                        FileHandle.standardError.write("mermaid: \(why.split(separator: "\n").first ?? "")\n".data(using: .utf8)!)
                    }
                    return
                }
                if self.highlightPending {
                    self.deferredPlacements.append { [weak self] in self?.place(image, for: block, dark: dark) }
                } else {
                    self.place(image, for: block, dark: dark)
                }
            }
        }
    }

    /// Put the diagram where the block's code (or its diagram for the other appearance) is.
    /// What is on screen stays where it is: a block above the visible part changes height
    /// without moving the text the reader is looking at.
    private func place(_ image: NSImage, for block: MermaidBlock, dark: Bool) {
        guard let storage = textView.textStorage, let lm = textView.layoutManager, let tc = textView.textContainer,
              dark == isDark, block.shownDark != dark else { return }
        var found: NSRange?
        storage.enumerateAttribute(MermaidBlock.key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value as AnyObject === block { found = found.map { NSUnionRange($0, range) } ?? range }
        }
        guard let range = found else { return }
        endHints()

        let top = clip.bounds.origin.y - textView.textContainerOrigin.y
        let before = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
        let heightBefore = lm.usedRect(for: tc).height
        storage.replaceCharacters(in: range, with: block.attributed(image, font: theme.body))
        block.shownDark = dark
        lm.ensureLayout(for: tc)
        if clip.bounds.origin.y > 0, before.maxY <= top {
            scroll(by: lm.usedRect(for: tc).height - heightBefore)
        }
    }

    /// Diagrams still on their way (tests).
    var diagramsInFlight: Int { diagramsPending + deferredPlacements.count }

    /// How far below the top of the visible part the first occurrence of `text` is (tests).
    func visibleOffset(of text: String) -> CGFloat? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let r = (textView.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        return rect.minY + textView.textContainerOrigin.y - clip.bounds.origin.y
    }

    private func show(error: String) {
        let s = NSAttributedString(string: error, attributes: [
            .font: theme.body, .foregroundColor: NSColor.systemRed,
        ])
        textView.textStorage?.setAttributedString(s)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        // "#heading" is resolved against the document, so it arrives as a file URL: catch it
        // before the file branch, which would reload the document and land at the top.
        if url.relativeString.hasPrefix("#"), let frag = url.fragment?.removingPercentEncoding {
            jump(toHeading: frag)
            return true
        }
        if url.isFileURL {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, !isDir.boolValue, FileKind.of(url).isViewable {
                // The delegate runs while the click is being dispatched, so the current event
                // carries the modifiers held at that moment. ⌘: a new tab; this one stays as it is.
                // A hint picked with `F` asks for the same (its key event carries no ⌘).
                let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                if followInNewTab || command { onOpenTab?(url) } else { onOpenFile?(url) }
            } else if exists {
                // Never hand arbitrary local files to Launch Services (a doc could link to a
                // script or app bundle); reveal in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSSound.beep()
            }
            return true
        }
        if url.scheme == nil || (url.fragment != nil && url.path.isEmpty) {
            // "#heading" anchors: best effort — search for the heading text.
            if let frag = url.fragment?.removingPercentEncoding {
                jump(toHeading: frag)
                return true
            }
        }
        // External links: only well-known schemes; custom URL schemes can launch arbitrary apps.
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            NSSound.beep()
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Link hints (`f` / `F`)

    private struct Hint {
        let label: String
        let link: Any
        let location: Int
        let view: LinkHintLabel
    }

    private var hints: [Hint] = []
    private var hintTyped = ""
    private var hintNewTab = false
    /// Set while a hint picked with `F` is being followed: a file viw can show opens in a new tab.
    private var followInNewTab = false

    /// The labels on screen (tests).
    var hintLabels: [String] { hints.map(\.label) }

    /// Label every link in sight; typing a label follows that link the way a click would.
    private func beginHints(newTab: Bool) {
        endHints()
        let links = visibleLinks()
        guard !links.isEmpty else { return }
        hintNewTab = newTab
        let visible = textView.visibleRect
        for (label, link) in zip(LinkHints.labels(count: links.count), links) {
            let v = LinkHintLabel(label: label)
            // Over the start of the link, kept inside what is visible.
            let x = min(max(link.rect.minX - 2, visible.minX), max(visible.minX, visible.maxX - v.frame.width))
            let y = min(max(link.rect.minY - 1, visible.minY), max(visible.minY, visible.maxY - v.frame.height))
            v.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
            textView.addSubview(v)
            hints.append(Hint(label: label, link: link.link, location: link.location, view: v))
        }
    }

    private func endHints() {
        guard !hints.isEmpty else { return }
        hints.forEach { $0.view.removeFromSuperview() }
        hints = []
        hintTyped = ""
    }

    @objc private func viewDidMove(_ note: Notification) { endHints() }

    func textViewDidChangeSelection(_ notification: Notification) { endHints() } // a click or drag in the text

    /// Links whose first line is in sight, top to bottom: the link, where it starts in the text
    /// and the rectangle of its first line (text view coordinates).
    private func visibleLinks() -> [(link: Any, location: Int, rect: NSRect)] {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, let storage = textView.textStorage else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        guard !visible.isEmpty else { return [] }
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var found: [(link: Any, location: Int, rect: NSRect)] = []
        storage.enumerateAttribute(.link, in: chars) { value, range, _ in
            guard let value, range.length > 0 else { return }
            // A link that wraps is labelled where it starts: the part on its first line.
            let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard g.length > 0 else { return }
            var line = NSRange()
            lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: &line)
            let first = NSIntersectionRange(g, line)
            let rect = lm.boundingRect(forGlyphRange: first, in: tc).offsetBy(dx: origin.x, dy: origin.y)
            if rect.intersects(visible) { found.append((value, range.location, rect)) }
        }
        return found
    }

    /// Keys while the hints are up: letters narrow the labels down, the last letter of a label
    /// follows its link, anything else cancels. Nothing reaches the vim keys.
    private func hintKey(_ event: NSEvent) -> Bool {
        guard !hints.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { endHints(); return false } // the menu bar's
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.specialKey == .delete, !hintTyped.isEmpty {
            hintTyped.removeLast()
        } else if !flags.contains(.control), chars.count == 1, LinkHints.alphabet.contains(chars) {
            hintTyped += chars
        } else {
            endHints() // Esc, ⌃[ and every key that is not part of a label
            return true
        }
        let matching = hints.filter { $0.label.hasPrefix(hintTyped) }
        if let hit = matching.first(where: { $0.label == hintTyped }) {
            let newTab = hintNewTab
            endHints()
            followInNewTab = newTab
            defer { followInNewTab = false }
            _ = textView(textView, clickedOnLink: hit.link, at: hit.location)
        } else if matching.isEmpty {
            endHints()
        } else {
            for h in hints {
                h.view.isHidden = !h.label.hasPrefix(hintTyped)
                h.view.typed = hintTyped.count
            }
        }
        return true
    }

    func followLinkInNewTab() { beginHints(newTab: true) }

    private func jump(toHeading slug: String) {
        guard let storage = textView.textStorage else { return }
        let wanted = slug.lowercased().replacingOccurrences(of: "-", with: " ")
        let text = storage.string as NSString
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { sub, range, _, stop in
            guard let sub else { return }
            let norm = sub.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: "", options: .regularExpression)
            if norm == wanted {
                found = range
                stop.pointee = true
            }
        }
        if let r = found {
            onJump?() // `H` returns to the link
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: g, in: tc)
                scroll(toY: rect.minY)
            }
        }
    }

    // MARK: - Scrolling

    private var clip: NSClipView { scrollView.contentView }
    private var lineStep: CGFloat { theme.lineHeight * 2 }
    private var pageStep: CGFloat { max(clip.bounds.height - theme.lineHeight * 2, theme.lineHeight) }
    private var maxY: CGFloat { max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height) }

    private func scroll(toY y: CGFloat) {
        var o = clip.bounds.origin
        o.y = min(max(0, y), maxY)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
        if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
            FileHandle.standardError.write("scrollY: \(Int(o.y)) / \(Int(maxY))\n".data(using: .utf8)!)
        }
    }

    private func scroll(by dy: CGFloat) { scroll(toY: clip.bounds.origin.y + dy) }

    var scrollPosition: NSPoint {
        get { clip.bounds.origin }
        set {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scroll(toY: newValue.y)
        }
    }

    func scrollLines(_ n: Int) { scroll(by: CGFloat(n) * lineStep) }
    func scrollHalfPages(_ n: Int) { scroll(by: CGFloat(n) * clip.bounds.height / 2) }
    func scrollPages(_ n: Int) { scroll(by: CGFloat(n) * pageStep) }
    func scrollToTop() { scroll(toY: 0) }

    func scrollToBottom() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scroll(toY: .greatestFiniteMagnitude)
    }

    func scrollToPercent(_ percent: Int) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scroll(toY: maxY * CGFloat(percent) / 100)
    }

    func scrollHorizontal(_ n: Int) {
        guard let doc = scrollView.documentView, doc.frame.width > clip.bounds.width else { return }
        var o = clip.bounds.origin
        o.x = min(max(0, o.x + CGFloat(n) * theme.lineHeight * 2), doc.frame.width - clip.bounds.width)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Find

    private func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    func find() { finderAction(.showFindInterface) }
    func filter() { beginHints(newTab: false) } // no rows to filter: `f` labels the links instead
    func sortRows() {}
    func unsortRows() {}
    func findNext(reverse: Bool) { finderAction(reverse ? .previousMatch : .nextMatch) }

    func copySelection() {
        let r = textView.selectedRange()
        guard r.length > 0 else { return }
        textView.copy(nil)
        var anchor: NSRect?
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: g, in: tc)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let visible = rect.intersection(textView.visibleRect)
            anchor = visible.isEmpty ? nil : scrollView.convert(visible, from: textView)
        }
        Toast.show(in: scrollView, "Copied", detail: (textView.string as NSString).substring(with: r), near: anchor)
    }

    func copyRow() { copySelection() }

    func clearSelection() {
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
    }

    func toggleDetail() {} // nothing to inspect in a text document
    func switchPane() {}

    // MARK: - Debug snapshot (VIW_SNAPSHOT=/path.png renders the whole document and quits)

    func snapshot(to path: String) {
        guard path != "/dev/null" else { return }
        if let w = ProcessInfo.processInfo.environment["VIW_SNAPSHOT_WIDTH"].flatMap(Double.init) {
            textView.setFrameSize(NSSize(width: CGFloat(w), height: textView.frame.height))
        }
        // Diagrams are drawn by a web view that answers on the main run loop: let it turn.
        let deadline = Date().addingTimeInterval(20)
        while diagramsPending > 0 || !deferredPlacements.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let bounds = textView.bounds
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        textView.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Files that are read as Markdown after a conversion (Word, PowerPoint, Jupyter).
enum Converted {
    static func handles(_ url: URL) -> Bool { ["docx", "pptx", "ipynb"].contains(url.pathExtension.lowercased()) }

    static func markdown(url: URL) throws -> (markdown: String, mediaDirectory: URL?) {
        switch url.pathExtension.lowercased() {
        case "docx": let r = try DOCX.markdown(url: url); return (r.markdown, r.mediaDirectory)
        case "ipynb": let r = try Notebook.markdown(url: url); return (r.markdown, r.mediaDirectory)
        case "pptx": let r = try PPTX.markdown(url: url); return (r.markdown, r.mediaDirectory)
        default: throw Notebook.Error(description: "no conversion for \(url.lastPathComponent)")
        }
    }
}
