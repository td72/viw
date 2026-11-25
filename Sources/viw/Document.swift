import AppKit

enum Source {
    case file(URL)
    case text(String, title: String)

    var url: URL? { if case .file(let u) = self { return u } else { return nil } }
    var title: String {
        switch self {
        case .file(let u): return u.lastPathComponent
        case .text(_, let t): return t
        }
    }
    /// The same file (or both the piped text): going back within it only scrolls.
    func isSameDocument(as other: Source) -> Bool {
        switch (self, other) {
        case (.file(let a), .file(let b)): return a == b
        case (.text, .text): return true
        default: return false
        }
    }
    /// Directory shown as the window subtitle, with `~` for home.
    var subtitle: String {
        guard let url else { return "" }
        let dir = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// How a file is rendered, decided by its name.
enum FileKind {
    case markdown
    case code(String) // tree-sitter language (fence info string)
    case json         // a tree (JSONDocumentView); `p`: pretty-printed text, `t`: an array of objects as a table
    case jsonl        // JSON Lines: the records as a tree; as text, one pretty-printed record per block
    case table        // CSV / TSV: grid view
    case workbook     // xlsx / xlsm: grid view with a sheet bar
    case database     // SQLite: grid view, one sheet per table / view
    case archive      // zip: a tree of the entries, Enter opens one in a tab
    case pdf          // PDFKit
    case image        // png / jpg / gif / heic / …
    case diagram      // drawio / dio: draw.io pages drawn by Drawio, shown like an image
    case video        // mp4 / mov / m4v (AVKit); mkv / webm / avi get a note
    case audio        // m4a / mp3 / wav / aiff / flac (AVKit)
    case notebook     // ipynb: converted to Markdown (Notebook)
    case presentation // pptx: converted to Markdown (PPTX), one section per slide
    case document     // docx / doc / rtf / rtfd / odt: NSAttributedString's importers, shown in the text view
    case plain        // unknown extension: one monochrome code block

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "txt"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "svg"]
    /// Recognised as video; only what AVFoundation decodes plays (the rest shows a note).
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "mkv", "webm", "avi", "flv", "mpg", "mpeg"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "ogg", "oga", "opus"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if ["json", "jsonc", "json5"].contains(ext) { return .json }
        if ["jsonl", "ndjson"].contains(ext) { return .jsonl }
        if ["csv", "tsv", "tab"].contains(ext) { return .table }
        if ["xlsx", "xlsm"].contains(ext) { return .workbook }
        if SQLiteDatabase.extensions.contains(ext) {
            // ".db" is used for all sorts of things: only a real SQLite header counts.
            return ext != "db" || SQLiteDatabase.isDatabase(url) ? .database : .plain
        }
        if ext == "pdf" { return .pdf }
        if ArchiveBrowser.extensions.contains(ext) { return .archive }
        if RichDocument.extensions.contains(ext) { return .document }
        if ext == "ipynb" { return .notebook }
        if ext == "pptx" { return .presentation }
        if imageExtensions.contains(ext) { return .image }
        if ext == "drawio" || ext == "dio" { return .diagram }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if ext.isEmpty {
            // "Dockerfile" & co. carry the language in the name; anything else without an extension reads as markdown.
            return Highlighter.language(for: url.lastPathComponent) != nil ? .code(url.lastPathComponent) : .markdown
        }
        return Highlighter.language(for: ext) != nil ? .code(ext) : .plain
    }

    static func of(_ source: Source) -> FileKind {
        if case .file(let url) = source { return of(url) } else { return .markdown }
    }

    /// JSON / JSON Lines: shown as a tree, as a table or as text.
    var isJSON: Bool {
        switch self {
        case .json, .jsonl: return true
        default: return false
        }
    }

    /// Something viw can show as text (used to decide whether a clicked file link opens in place).
    var isViewable: Bool { if case .plain = self { return false } else { return true } }
}

/// The content area of one tab. `TextDocumentView` (NSTextView) is the only implementation
/// today; tables (CSV / xlsx), PDF and images add their own, and `DocumentController` picks
/// one by `FileKind`. Everything a format must offer to the tab, the vim keys and the menus
/// is here, so the rest of the app never touches the concrete view.
protocol DocumentView: AnyObject {
    init()
    /// Root view, sized by the window to the tab's content area.
    var view: NSView { get }
    /// Tells the controller what to do with a file link the user clicked inside the content.
    var onOpenFile: ((URL) -> Void)? { get set }
    /// Open `url` in a new tab (zip entries); views that never do so keep the default.
    var onOpenTab: ((URL) -> Void)? { get set }
    /// Called just before the view jumps within the document (a `#heading` link), so the
    /// controller can remember where the reader was; views that never jump keep the default.
    var onJump: (() -> Void)? { get set }
    /// Where the content is scrolled to, for the back / forward history. Views that do not
    /// restore a position keep the default (they come back at the top).
    var scrollPosition: NSPoint { get set }
    /// Receiver of the vim keys typed into the content.
    var commands: ViewerCommands? { get set }
    /// Extra for the window subtitle ("3 / 12" pages, image size); `onStatusChange` fires when it changes.
    var status: String? { get }
    var onStatusChange: (() -> Void)? { get set }

    /// (Re)load the content. `preserveScroll` keeps the position on reload (file change, zoom).
    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool)
    /// Make the right subview first responder so vim keys reach it.
    func focus()

    func scrollLines(_ n: Int)
    func scrollHalfPages(_ n: Int)
    func scrollPages(_ n: Int)
    func scrollHorizontal(_ n: Int)
    func scrollToTop()
    func scrollToBottom()
    func scrollToPercent(_ percent: Int)
    func find()
    /// `f`: filter rows, where the view has rows; text documents show link hints instead.
    func filter()
    /// `F`: link hints whose link opens in a new tab; views without links ignore it.
    func followLinkInNewTab()
    /// `s` / `S`: sort rows / restore file order, where the view has rows.
    func sortRows()
    func unsortRows()
    func findNext(reverse: Bool)
    /// `y`: put the selection on the pasteboard.
    func copySelection()
    /// `Y`: the whole row (tables); the same as `y` elsewhere.
    func copyRow()
    /// Esc: drop the selection (and any search state).
    func clearSelection()
    /// `v` / `V` / `⌃v`: visual mode, where the view has cells to select (tables).
    func toggleVisual(_ mode: VisualMode)
    /// `m`: the visual selection as a Markdown table; false when there is none.
    func copyMarkdown() -> Bool
    /// `C`: the whole column under the cursor, where the view has columns (tables).
    func copyColumn()
    /// The fold keys and `J` / `K`, where the view is a tree that folds (JSON).
    func fold(_ action: FoldAction)
    func moveSibling(_ n: Int)
    /// `]]` / `[[` between headings, where the view has them (text).
    var headingMotions: Bool { get }
    func moveHeading(_ n: Int)
    /// `.`: show / hide a detail pane, where the view has one.
    func toggleDetail()
    /// Enter / `i` / `⌃w w`: move focus between the main view and its pane, where the view has one.
    func switchPane()

    /// `+` / `-` / `=`: views with their own scale (PDF, images) return true; text views leave it
    /// to the theme (font size).
    func zoomView(_ delta: Int) -> Bool
    func resetZoomView() -> Bool
    /// `r` / `R`: quarter turns clockwise; views that can rotate (PDF, images) return true, and
    /// then `r` rotates instead of reloading (the file watcher and ⌘R still reload).
    func rotate(_ quarterTurns: Int) -> Bool
    /// `p`: PDF page view ⇄ continuous; views without pages return false.
    func togglePageMode() -> Bool
    /// `t`: PDF page overview; nil where there is none.
    func toggleThumbnails() -> Bool?
    /// `]` / `[`: next / previous sheet of a workbook; other views ignore it.
    func selectSheet(offset: Int)
    /// The view's own keys for the `?` overlay (after the common ones).
    var helpSections: [KeyHelp.Section] { get }
    /// Space: play / pause (animated images, media); false where there is nothing to play.
    func togglePlayback() -> Bool
    /// `m`: mute / unmute (media).
    func toggleMute()

    /// Debug: render the whole content to a PNG (VIW_SNAPSHOT).
    func snapshot(to path: String)
}

extension DocumentView {
    var onOpenTab: ((URL) -> Void)? { get { nil } set {} }
    var onJump: (() -> Void)? { get { nil } set {} }
    var scrollPosition: NSPoint { get { .zero } set {} }

    var status: String? { nil }
    func zoomView(_ delta: Int) -> Bool { false }
    func resetZoomView() -> Bool { false }
    func rotate(_ quarterTurns: Int) -> Bool { false }
    func togglePageMode() -> Bool { false }
    func toggleThumbnails() -> Bool? { nil }
    func selectSheet(offset: Int) {}
    func followLinkInNewTab() {}
    func toggleVisual(_ mode: VisualMode) {}
    func copyMarkdown() -> Bool { false }
    func copyColumn() {}
    func fold(_ action: FoldAction) {}
    func moveSibling(_ n: Int) {}
    var headingMotions: Bool { false }
    func moveHeading(_ n: Int) {}
    var helpSections: [KeyHelp.Section] { [] }
    func togglePlayback() -> Bool { false }
    func toggleMute() {}
}

/// What a document needs from the window that hosts it as a tab.
protocol DocumentHost: AnyObject {
    func documentDidChangeTitle(_ doc: DocumentController)
    func documentDidChangeTheme(_ doc: DocumentController)
    /// The document swapped its `DocumentView` (a link led to a different kind of file).
    func documentDidReplaceView(_ doc: DocumentController)
    func open(_ urls: [URL])
    func close(_ doc: DocumentController)
    func selectTab(offset: Int)
    func selectTab(index: Int)
    /// `?`: show the key list over the window.
    func showHelp(for doc: DocumentController)
}

/// One document = one tab: the source, its kind, the theme, the file watcher and the
/// `DocumentView` that draws it. Implements the vim commands by forwarding navigation to
/// the view and handling the rest (reload, zoom, open, close, tabs) itself.
final class DocumentController: NSObject, ViewerCommands {
    private(set) var source: Source
    private(set) var kind: FileKind
    private var theme = Theme.load()
    private(set) var documentView: DocumentView
    private var watcher: FileWatcher?
    /// Where the links followed in this tab came from (`H` / `L`); reloads never touch it.
    private var history = NavigationHistory<HistoryEntry>()
    weak var host: DocumentHost?
    /// How a JSON document is shown (`p` / `t` switch): `.table` is the array of objects at
    /// `jsonTablePath`. JSON that does not parse is text whatever this says.
    private enum JSONMode { case tree, text, table }
    private var jsonMode = JSONMode.tree
    private var jsonTablePath: [JSONNode.Step] = []
    /// The other views of the same JSON file, kept so that switching back finds the tree
    /// folded and scrolled as it was left.
    private var parkedViews: [ObjectIdentifier: DocumentView] = [:]

    /// One stop in the tab's history: the document and how far it was scrolled.
    private struct HistoryEntry {
        let source: Source
        let scroll: NSPoint
    }

    var view: NSView { documentView.view }
    var title: String { source.title }

    init(source: Source) {
        self.source = source
        self.kind = FileKind.of(source)
        self.documentView = (kind.isJSON && JSONSource.read(source, kind) != nil ? JSONDocumentView.self : Self.viewType(for: kind)).init()
        super.init()
        bind(documentView)
        load()
        startWatching()
    }

    /// Stop watching the file (the tab is going away).
    func stop() { watcher = nil }

    func focus() { documentView.focus() }

    private func bind(_ v: DocumentView) {
        v.onOpenFile = { [weak self] url in self?.open(url) }
        v.onOpenTab = { [weak self] url in self?.host?.open([url]) }
        v.onJump = { [weak self] in self?.rememberPosition() }
        v.onStatusChange = { [weak self] in self.map { $0.host?.documentDidChangeTitle($0) } }
        v.commands = self
    }

    /// Which `DocumentView` draws `kind`; the same class is reused across loads.
    private static func viewType(for kind: FileKind) -> DocumentView.Type {
        switch kind {
        case .table, .workbook, .database: return TableDocumentView.self
        case .archive: return ArchiveDocumentView.self
        case .pdf: return PDFDocumentView.self
        case .image, .diagram: return ImageDocumentView.self
        case .video, .audio: return MediaDocumentView.self
        default: return TextDocumentView.self
        }
    }

    /// The view for the document as it is now: `viewType(for:)`, except that JSON follows
    /// `jsonMode` as far as the file allows (not JSON → text; no such array → the tree).
    private func wantedViewType() -> DocumentView.Type {
        guard kind.isJSON else { return Self.viewType(for: kind) }
        guard jsonMode != .text, let root = JSONSource.read(source, kind) else { return TextDocumentView.self }
        if jsonMode == .table, root.node(at: jsonTablePath)?.isTabular == true { return TableDocumentView.self }
        jsonMode = .tree
        return JSONDocumentView.self
    }

    /// Window subtitle: the directory, plus the view's status (page, image size).
    var subtitle: String {
        [source.subtitle, documentView.status ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Loading

    func load(preserveScroll: Bool = true) {
        theme = Theme.load() // re-read config on every (re)load so `r` picks up edits
        let wanted = wantedViewType()
        if type(of: documentView) != wanted {
            if kind.isJSON { parkedViews[ObjectIdentifier(type(of: documentView))] = documentView }
            documentView = parkedViews.removeValue(forKey: ObjectIdentifier(wanted)) ?? wanted.init()
            bind(documentView)
            host?.documentDidReplaceView(self)
        }
        (documentView as? TableDocumentView)?.jsonPath = jsonTablePath
        documentView.load(source: source, kind: kind, theme: theme, preserveScroll: preserveScroll)
        host?.documentDidChangeTitle(self)
    }

    private func startWatching() {
        watcher = nil
        guard let url = source.url else { return }
        watcher = FileWatcher(path: url.path) { [weak self] in self?.load() }
    }

    /// Replace this tab's document (relative links navigate in place); `H` comes back.
    func open(_ url: URL) {
        rememberPosition()
        source = .file(url.standardizedFileURL)
        kind = FileKind.of(source)
        resetJSONViews()
        load(preserveScroll: false)
        documentView.scrollToTop()
        startWatching()
    }

    /// Another document: it starts as a tree, and the views parked for the last one go.
    private func resetJSONViews() {
        jsonMode = .tree
        jsonTablePath = []
        parkedViews = [:]
    }

    // MARK: - History

    private var position: HistoryEntry { HistoryEntry(source: source, scroll: documentView.scrollPosition) }

    /// A link is about to be followed (to another file or to a heading): push where we are.
    private func rememberPosition() { history.push(position) }

    func goBack(_ n: Int) {
        if let entry = history.goBack(n, from: position) { restore(entry) }
    }

    func goForward(_ n: Int) {
        if let entry = history.goForward(n, from: position) { restore(entry) }
    }

    private func restore(_ entry: HistoryEntry) {
        if !entry.source.isSameDocument(as: source) {
            source = entry.source
            kind = FileKind.of(source)
            resetJSONViews()
            load(preserveScroll: false)
            startWatching()
        }
        documentView.scrollPosition = entry.scroll
    }

    // MARK: - Swipe

    /// The slide under way, and which way it went.
    private var swipe: (transition: SwipeTransition, back: Bool)?

    func swipeBegan(back: Bool) -> Bool {
        guard swipe == nil, back ? history.canGoBack : history.canGoForward else { return false }
        let leaving = view.snapshotImage()
        if back { goBack(1) } else { goForward(1) }
        swipe = (SwipeTransition(leaving: leaving, page: view, back: back), back)
        return true
    }

    func swipeMoved(_ progress: CGFloat) { swipe?.transition.move(to: progress) }

    func swipeEnded(completed: Bool) {
        guard let (transition, back) = swipe else { return }
        swipe = nil
        transition.end()
        if !completed { if back { goForward(1) } else { goBack(1) } }
    }

    // MARK: - ViewerCommands

    func scrollLines(_ n: Int) { documentView.scrollLines(n) }
    func scrollHalfPages(_ n: Int) { documentView.scrollHalfPages(n) }
    func scrollPages(_ n: Int) { documentView.scrollPages(n) }
    func scrollHorizontal(_ n: Int) { documentView.scrollHorizontal(n) }
    func scrollToTop() { documentView.scrollToTop() }
    func scrollToBottom() { documentView.scrollToBottom() }
    func scrollToPercent(_ percent: Int) { documentView.scrollToPercent(percent) }
    func find() { documentView.find() }
    func filter() { documentView.filter() }
    func followLinkInNewTab() { documentView.followLinkInNewTab() }
    func sortRows() { documentView.sortRows() }
    func unsortRows() { documentView.unsortRows() }
    func findNext(reverse: Bool) { documentView.findNext(reverse: reverse) }
    func copySelection() { documentView.copySelection() }
    func copyRow() { documentView.copyRow() }
    func toggleVisual(_ mode: VisualMode) { documentView.toggleVisual(mode) }
    func copyMarkdown() -> Bool { documentView.copyMarkdown() }
    func copyColumn() { documentView.copyColumn() }
    func fold(_ action: FoldAction) { documentView.fold(action) }
    func moveSibling(_ n: Int) { documentView.moveSibling(n) }
    var headingMotions: Bool { documentView.headingMotions }
    func moveHeading(_ n: Int) { documentView.moveHeading(n) }
    func clearSelection() { documentView.clearSelection() }
    func toggleDetail() { documentView.toggleDetail() }
    func switchPane() { documentView.switchPane() }

    func reload() { if !documentView.rotate(1) { load() } }
    func rotateBack() { _ = documentView.rotate(-1) }
    func closeWindow() { host?.close(self) }
    func selectTab(offset: Int) { host?.selectTab(offset: offset) }
    func selectTab(index: Int) { host?.selectTab(index: index) }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = source.url?.deletingLastPathComponent()
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.host?.open(panel.urls)
        }
    }

    /// `p` / View › PDF Page View: one page at a time ⇄ continuous, remembered like the zoom level.
    func togglePageMode() {
        if kind.isJSON { // `p`: the tree (or the table) ⇄ the pretty-printed text
            jsonMode = jsonMode == .text ? .tree : .text
            return load()
        }
        guard documentView.togglePageMode() else { return }
        theme.pdfContinuous.toggle()
        theme.save()
        host?.documentDidChangeTitle(self)
    }

    /// `t` / View › PDF Thumbnails: the page overview.
    func toggleThumbnails() {
        guard kind.isJSON else { _ = documentView.toggleThumbnails(); return }
        // `t`: the array of objects under the cursor as a table, and back to the tree.
        if jsonMode == .table {
            jsonMode = .tree
        } else {
            // From the text, the cursor is where the tree was left.
            let tree = (documentView as? JSONDocumentView) ?? (parkedViews[ObjectIdentifier(JSONDocumentView.self)] as? JSONDocumentView)
            let root = JSONSource.read(source, kind)
            guard let array = tree?.tableCandidate ?? (root?.isTabular == true ? root : nil) else {
                Toast.show(in: view, "No array of objects here", detail: root == nil ? "the file is not valid JSON" : "put the cursor on one (or inside it) and press t")
                return
            }
            jsonTablePath = array.steps
            jsonMode = .table
        }
        load()
    }

    /// `]` / `[` / View › Next / Previous Sheet (xlsx).
    func selectSheet(offset: Int) { documentView.selectSheet(offset: offset) }

    func showHelp() { host?.showHelp(for: self) }
    func togglePlayback() -> Bool { documentView.togglePlayback() }
    func toggleMute() { documentView.toggleMute() }
    var helpSections: [KeyHelp.Section] {
        // JSON shown as text or as a table: how to get back to the tree.
        documentView.helpSections + (kind.isJSON && !(documentView is JSONDocumentView) ? [KeyHelp.jsonViews] : [])
    }

    /// `I` / View › Detail Pane: right ⇄ bottom, remembered like the zoom level.
    func togglePanePosition() {
        theme.detailPaneOnRight.toggle()
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func zoom(_ delta: Int) {
        if documentView.zoomView(delta) { host?.documentDidChangeTitle(self); return }
        let steps: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36]
        let i = steps.firstIndex { $0 >= theme.baseSize } ?? 5
        theme.baseSize = steps[max(0, min(steps.count - 1, i + delta))]
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func resetZoom() {
        if documentView.resetZoomView() { host?.documentDidChangeTitle(self); return }
        theme.baseSize = theme.defaultSize
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func revealInFinder() {
        if let u = source.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func snapshot(to path: String) { documentView.snapshot(to: path) }
}
