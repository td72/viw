import AppKit
import WebKit

/// A ```mermaid block of a Markdown document. The object itself is the value of the
/// `MermaidBlock.key` attribute on whatever stands for the block in the text — its code at first,
/// the drawn diagram later — so the block is found again however the text around it has shifted.
final class MermaidBlock {
    static let key = NSAttributedString.Key("viw.mermaid")

    let source: String
    /// Paragraph style of the line that holds the diagram (indent, enclosing quote / list).
    let style: NSParagraphStyle
    /// Room for the diagram, in points.
    let width: CGFloat
    /// Points per CSS pixel: mermaid draws for a 16 px body, viw's body size may differ.
    let scale: CGFloat
    /// Appearance of the diagram in the text right now; nil while the code is shown.
    var shownDark: Bool?

    init(source: String, style: NSParagraphStyle, width: CGFloat, scale: CGFloat) {
        self.source = source
        self.style = style
        self.width = width
        self.scale = scale
    }

    func request(dark: Bool) -> MermaidRenderer.Request {
        MermaidRenderer.Request(source: source, dark: dark, width: max(200, Int((width / scale).rounded())))
    }

    /// The diagram as text: one attachment on its own line, scaled to the body size and shrunk to fit.
    func attributed(_ image: NSImage, font: NSFont) -> NSAttributedString {
        var size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        if size.width > width, width > 0 {
            size.height *= width / size.width
            size.width = width
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: size)
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "\n"))
        s.addAttributes([.font: font, .paragraphStyle: style, MermaidBlock.key: self],
                        range: NSRange(location: 0, length: s.length))
        return s
    }
}

/// Draws Mermaid diagrams with the official mermaid.js in one web view that is never shown:
/// source in, the diagram as a vector image (PDF) out. Main thread only; requests run one at a
/// time. The web view starts with the first diagram, so documents without one never pay for it.
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    struct Request: Hashable {
        let source: String
        let dark: Bool
        /// Width of the page in CSS pixels. Most diagrams have a size of their own; a gantt chart fills it.
        let width: Int
    }

    enum Outcome {
        case image(NSImage)
        /// A syntax error (mermaid's message) or the renderer being unavailable.
        case failed(String)
    }

    private var cache: [Request: Outcome] = [:]
    private var queue: [(request: Request, completions: [(Outcome) -> Void])] = []
    private var web: WKWebView?
    private var ready = false
    /// Bumped whenever the head of the queue starts or ends, so a late callback or timeout is dropped.
    private var run = 0
    private var busy = false

    /// mermaid.min.js, index.html and render.js: SwiftPM's resource bundle, in the app's
    /// Resources (also when viw was started through the CLI symlink, where `Bundle.main` is
    /// not the app) or next to the executable (`swift build`, tests).
    static let resources: URL? = {
        let roots = [installedAppBundle()?.resourceURL, Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle(for: MermaidRenderer.self).bundleURL.deletingLastPathComponent()]
        for root in roots {
            guard let root, let dir = Bundle(url: root.appendingPathComponent("viw_viw.bundle"))?
                .resourceURL?.appendingPathComponent("Mermaid") else { continue }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("mermaid.min.js").path) { return dir }
        }
        return nil
    }()

    /// The diagram if it was drawn before: a reload or a step back shows it at once.
    func cached(_ request: Request) -> NSImage? {
        if case .image(let image)? = cache[request] { return image }
        return nil
    }

    /// `completion` runs on the main thread — before this returns when the answer is cached.
    func render(_ request: Request, completion: @escaping (Outcome) -> Void) {
        if let known = cache[request] { completion(known); return }
        if let i = queue.firstIndex(where: { $0.request == request }) {
            queue[i].completions.append(completion)
        } else {
            queue.append((request, [completion]))
        }
        pump()
    }

    private func pump() {
        guard !busy, let request = queue.first?.request else { return }
        guard let dir = Self.resources else { finish(.failed("mermaid.js is not installed"), cache: false); return }
        guard let web else { start(dir); return }
        guard ready else { return }

        busy = true
        run += 1
        let run = self.run
        // A diagram that never comes back (a runaway layout) must not hold up the ones after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, run == self.run, self.busy else { return }
            self.discardWebView()
            self.finish(.failed("timed out"), cache: true)
        }
        web.setFrameSize(NSSize(width: CGFloat(request.width), height: 800))
        web.callAsyncJavaScript(
            "return await renderDiagram(source, theme)",
            arguments: ["source": request.source, "theme": request.dark ? "dark" : "default"],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self, run == self.run else { return }
            switch result {
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.finish(.failed(message ?? error.localizedDescription), cache: true)
            case .success(let value):
                guard let size = value as? [String: Any],
                      let w = size["width"] as? Double, let h = size["height"] as? Double, w > 0, h > 0 else {
                    self.finish(.failed("empty diagram"), cache: true)
                    return
                }
                let pdf = WKPDFConfiguration()
                pdf.rect = CGRect(x: 0, y: 0, width: w.rounded(.up), height: h.rounded(.up))
                web.createPDF(configuration: pdf) { [weak self] result in
                    guard let self, run == self.run else { return }
                    if case .success(let data) = result, let image = NSImage(data: data), image.size.width > 0 {
                        self.finish(.image(image), cache: true)
                    } else {
                        self.finish(.failed("could not capture the diagram"), cache: true)
                    }
                }
            }
        }
    }

    private func finish(_ outcome: Outcome, cache store: Bool) {
        guard !queue.isEmpty else { return }
        let done = queue.removeFirst()
        run += 1
        busy = false
        if store {
            if cache.count >= 256 { cache.removeAll() }
            cache[done.request] = outcome
        }
        done.completions.forEach { $0(outcome) }
        pump()
    }

    // MARK: - Web view

    private func start(_ dir: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 948, height: 800), configuration: config)
        web.setValue(false, forKey: "drawsBackground") // the diagram goes over the document's own background
        web.navigationDelegate = self
        self.web = web
        ready = false
        // Read access ends at the Mermaid directory: the page cannot reach the user's files.
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    private func discardWebView() {
        web?.navigationDelegate = nil
        web = nil
        ready = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        pump()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        unavailable(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        unavailable(error)
    }

    /// Only the page itself is ever loaded: links in a diagram go nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let own = navigationAction.request.url?.lastPathComponent == "index.html" && navigationAction.request.url?.isFileURL == true
        decisionHandler(own ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        discardWebView()
        if busy { finish(.failed("the renderer stopped"), cache: true) } else { pump() }
    }

    /// The page did not load: every waiting diagram stays code.
    private func unavailable(_ error: Error) {
        discardWebView()
        busy = false
        while !queue.isEmpty { finishWithoutPump(.failed(error.localizedDescription)) }
    }

    private func finishWithoutPump(_ outcome: Outcome) {
        let done = queue.removeFirst()
        run += 1
        done.completions.forEach { $0(outcome) }
    }
}
