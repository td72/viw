import AppKit

/// Actions a content view forwards to its owner (the document controller).
protocol ViewerCommands: AnyObject {
    func scrollLines(_ n: Int)
    func scrollHalfPages(_ n: Int)
    func scrollPages(_ n: Int)
    func scrollHorizontal(_ n: Int)
    func scrollToTop()
    func scrollToBottom()
    func scrollToPercent(_ percent: Int)
    func find()
    /// `f`: filter rows (tables) / link hints (text); `⌃f` / Space / PgDn page forward instead.
    func filter()
    /// `F`: link hints whose link opens in a new tab (text).
    func followLinkInNewTab()
    /// `s` / `S`: sort rows / restore file order (tables).
    func sortRows()
    func unsortRows()
    func findNext(reverse: Bool)
    func copySelection()
    /// `Y`: the whole line / row (tables: the row as TSV; `y` is the cell).
    func copyRow()
    /// `C`: the whole column under the cursor (tables).
    func copyColumn()
    /// `za` / `zo` / `zc`, `e` / `c`, `zR` / `zM`: folds in a tree (JSON).
    func fold(_ action: FoldAction)
    /// `J` / `K`: the next / previous sibling in a tree, skipping what is inside (JSON).
    func moveSibling(_ n: Int)
    /// `v` / `V` / `⌃v`: visual mode in a table — select a block of cells / whole rows / whole
    /// columns; `y` copies it as TSV, `Y` with the header row.
    func toggleVisual(_ mode: VisualMode)
    /// `m` in visual mode: the selection as a Markdown table; false where there is none (→ mute).
    func copyMarkdown() -> Bool
    func clearSelection()
    /// `.`: show / hide the detail pane (tables: the selected row in full).
    func toggleDetail()
    /// Enter / `i` (or `⌃w w` / `⌃w h/j/k/l`): move the keyboard focus between the main view and its pane.
    func switchPane()
    /// `I`: move the detail pane between the right side and the bottom.
    func togglePanePosition()
    /// `p`: PDF page view ⇄ continuous scrolling.
    func togglePageMode()
    /// `t`: PDF page overview (a grid of thumbnails) ⇄ the document.
    func toggleThumbnails()
    /// `]` / `[`: next / previous sheet (xlsx).
    func selectSheet(offset: Int)
    /// `?`: the key list for the current view.
    func showHelp()
    /// Space: play / pause where the view plays something (animated images, media); false → page down.
    func togglePlayback() -> Bool
    /// `m`: mute / unmute (media).
    func toggleMute()
    func reload()
    /// `R`: rotate counter-clockwise (PDF / images; `r` rotates clockwise there instead of reloading).
    func rotateBack()
    func openFile()
    func closeWindow()
    func selectTab(offset: Int)
    func selectTab(index: Int)
    func zoom(_ delta: Int)
    func resetZoom()
    /// `H` / `⌃o`, `L`: back / forward through the links followed in this tab (`3H`: three steps).
    func goBack(_ n: Int)
    func goForward(_ n: Int)
    /// A two-finger swipe back / forward, sliding the pages like Safari: `swipeBegan` goes
    /// there at once (false: nowhere to go), `swipeMoved` follows the fingers (0 … 1) and
    /// `swipeEnded` settles it — a swipe that was not completed returns to where it began.
    func swipeBegan(back: Bool) -> Bool
    func swipeMoved(_ progress: CGFloat)
    func swipeEnded(completed: Bool)
}

extension ViewerCommands {
    // Only the document controller slides pages.
    func swipeBegan(back: Bool) -> Bool { false }
    func swipeMoved(_ progress: CGFloat) {}
    func swipeEnded(completed: Bool) {}

    func followLinkInNewTab() {} // only the document controller has links to follow
    // The grid only; the detail pane selects text with the mouse.
    func toggleVisual(_ mode: VisualMode) {}
    func copyMarkdown() -> Bool { false }
    func copyColumn() {}
    // Trees only.
    func fold(_ action: FoldAction) {}
    func moveSibling(_ n: Int) {}
}

/// What the fold keys do to a tree: to the node under the cursor, to it and everything inside
/// it, or to the whole tree (`openAll(depth: 2)`: two levels open, the rest folded).
enum FoldAction {
    case toggle, open, close
    case openSubtree, closeSubtree
    case openAll(depth: Int?), closeAll
}

/// What a visual selection in a table is made of.
enum VisualMode { case cells, rows, columns }

/// vim-style key handling shared by the text view and the table view: counts (`5j`),
/// `gg` / `G` / `50G`, tabs (`gt`, `⌘1`…), scrolling, find, zoom. Mouse / trackpad scrolling
/// and ⌘ menu shortcuts are untouched.
struct VimKeyMap {
    private var count = 0
    private var pendingG = false
    private var pendingWindow = false // after ⌃w
    private var pendingFold = false   // after z

    /// Returns false when the view's own `keyDown` should run (⌘ shortcuts for the menu bar).
    mutating func handle(_ event: NSEvent, _ c: ViewerCommands) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let n = max(count, 1)
        let hasCount = count > 0
        defer { if !(chars.first?.isNumber ?? false) && chars != "g" && !pendingFold { count = 0; pendingG = false } }

        if pendingWindow { // ⌃w + w / h / j / k / l / p: the only other window is the pane
            pendingWindow = false
            if ["w", "h", "j", "k", "l", "p"].contains(chars) { c.switchPane() }
            return true
        }

        if pendingFold { // z + a / o / c / R / M, as in vim (2zR: two levels open)
            pendingFold = false
            switch chars {
            case "a": c.fold(.toggle)
            case "o": c.fold(.open)
            case "c": c.fold(.close)
            case "R": c.fold(.openAll(depth: hasCount ? count : nil))
            case "M": c.fold(.closeAll)
            default: break
            }
            return true
        }

        if flags.contains(.command) {
            // ⌘1…⌘8 → nth tab, ⌘9 → last tab (browser convention); the rest is the menu bar's.
            if flags == .command, let d = Int(chars), 1...9 ~= d {
                c.selectTab(index: d == 9 ? .max : d - 1)
                return true
            }
            return false
        }

        if flags.contains(.control) {
            switch chars {
            case "e": c.scrollLines(n)
            case "y": c.scrollLines(-n)
            case "d": c.scrollHalfPages(n)
            case "u": c.scrollHalfPages(-n)
            case "f": c.scrollPages(n)
            case "b": c.scrollPages(-n)
            case "[": c.clearSelection() // like Esc
            case "w": pendingWindow = true
            case "v": c.toggleVisual(.columns) // vim's block mode; `v` is already a block here
            case "o": c.goBack(n) // vim's jump list; ⌃i is Tab (the next tab), so forward is `L` only
            default: break
            }
            return true
        }

        if let key = event.specialKey {
            switch key {
            case .downArrow: c.scrollLines(n)
            case .upArrow: c.scrollLines(-n)
            case .leftArrow: c.scrollHorizontal(-n)
            case .rightArrow: c.scrollHorizontal(n)
            case .pageDown: c.scrollPages(n)
            case .pageUp: c.scrollPages(-n)
            case .home: c.scrollToTop()
            case .end: c.scrollToBottom()
            case .tab: c.selectTab(offset: n) // Tab / Shift-Tab cycle through tabs
            case .backTab: c.selectTab(offset: -n)
            case .carriageReturn, .enter: c.switchPane() // Enter: into the detail pane (Esc comes back)
            default: break
            }
            return true
        }

        switch chars {
        case "]": c.selectSheet(offset: n)  // next / previous sheet (3]: three ahead)
        case "[": c.selectSheet(offset: -n)
        case "0"..."9":
            if chars == "0" && !hasCount { c.scrollHorizontal(-1_000_000) } // `0` → far left
            else { count = count * 10 + Int(chars)! }
            pendingG = false
        case "g":
            if pendingG { c.scrollToTop(); pendingG = false; count = 0 } else { pendingG = true }
        case "G":
            if hasCount { c.scrollToPercent(min(100, count)) } else { c.scrollToBottom() }
        case "t" where pendingG: // gt / 3gt
            if hasCount { c.selectTab(index: count - 1) } else { c.selectTab(offset: 1) }
        case "T" where pendingG: // gT
            c.selectTab(offset: -n)
        case "j": c.scrollLines(n)
        case "k": c.scrollLines(-n)
        case "h": c.scrollHorizontal(-n)
        case "l": c.scrollHorizontal(n)
        case "$": c.scrollHorizontal(1_000_000)
        case "H": c.goBack(n)
        case "L": c.goForward(n)
        case "d": c.scrollHalfPages(n)
        case "u": c.scrollHalfPages(-n)
        case " ": if !c.togglePlayback() { flags.contains(.shift) ? c.scrollPages(-n) : c.scrollPages(n) }
        case "b": c.scrollPages(-n) // forward is ⌃f / Space / PgDn; `f` is the filter / link hints (`b` kept for symmetry with ⌃b)
        case "/": c.find()
        case "f": c.filter()
        case "F": c.followLinkInNewTab()
        case "s": c.sortRows()
        case "S": c.unsortRows()
        case "n": c.findNext(reverse: false)
        case "N": c.findNext(reverse: true)
        case "y": c.copySelection()
        case "Y": c.copyRow()
        case "C": c.copyColumn()
        case "z": pendingFold = true
        case "e": c.fold(.openSubtree)
        case "c": c.fold(.closeSubtree)
        case "J": c.moveSibling(n)
        case "K": c.moveSibling(-n)
        case "v": c.toggleVisual(.cells)
        case "V": c.toggleVisual(.rows)
        case "i": c.switchPane()       // like Enter: into the detail pane
        case ".": c.toggleDetail()     // show / hide the detail pane
        case "I": c.togglePanePosition()
        case "p": c.togglePageMode()
        case "t": c.toggleThumbnails()
        case "r": c.reload()
        case "R": c.rotateBack()
        case "o": c.openFile()
        case "q": c.closeWindow()
        case "+", "=": chars == "=" && !flags.contains(.shift) ? c.resetZoom() : c.zoom(1)
        case "?": c.showHelp()
        case "m": if !c.copyMarkdown() { c.toggleMute() }
        case "-": c.zoom(-1)
        case "\u{1B}": c.clearSelection() // Esc: clear pending count & selection
        default:
            break // swallow silently (no beep) — read-only views
        }
        return true
    }
}
