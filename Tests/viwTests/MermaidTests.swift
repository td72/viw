import AppKit
import Foundation
import Markdown
import Testing
@testable import viw

@Suite struct MermaidTests {
    @Test func fenceInfo() {
        #expect(MarkdownRenderer.isMermaid("mermaid"))
        #expect(MarkdownRenderer.isMermaid("Mermaid title=x"))
        #expect(!MarkdownRenderer.isMermaid("mermaidx"))
        #expect(!MarkdownRenderer.isMermaid("swift"))
        #expect(!MarkdownRenderer.isMermaid(nil))
    }

    /// Until the diagram is drawn the block is its code, tagged so the text view can find it.
    @Test @MainActor func blockIsCodeCarryingItsSource() throws {
        let source = "graph TD\n  A[never drawn \(UUID().uuidString)] --> B\n"
        let renderer = MarkdownRenderer(theme: Theme(), baseURL: nil, columnWidth: 600)
        let out = renderer.render(Document(parsing: "before\n\n```mermaid\n\(source)```\n\n```swift\nlet a = 1\n```\n"))
        var blocks: [(MermaidBlock, NSRange)] = []
        out.enumerateAttribute(MermaidBlock.key, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if let b = value as? MermaidBlock { blocks.append((b, range)) }
        }
        let (block, range) = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(block.source == source)
        #expect(block.shownDark == nil)
        #expect(block.width == 600)
        #expect((out.string as NSString).substring(with: range).hasPrefix("graph TD\n"))
        #expect(renderer.codeBlocks.map(\.language) == ["swift"]) // mermaid is not sent to the highlighter
    }

    /// The whole path: mermaid.js in the web view, the diagram back as an image; then the cache.
    @Test @MainActor func drawsAndCaches() async throws {
        try #require(MermaidRenderer.resources != nil, "mermaid.js is not in the build")
        let request = MermaidRenderer.Request(source: "graph LR\n  A[開始] --> B[終了]\n", dark: false, width: 800)
        let outcome = await withCheckedContinuation { c in MermaidRenderer.shared.render(request) { c.resume(returning: $0) } }
        guard case .image(let image) = outcome else { Issue.record("no diagram: \(outcome)"); return }
        #expect(image.size.width > 100 && image.size.width < 800)
        #expect(image.size.height > 20)
        #expect(MermaidRenderer.shared.cached(request) != nil)

        // Drawn before → the renderer emits the diagram itself, one attachment on its own line.
        let out = MarkdownRenderer(theme: Theme(), baseURL: nil, columnWidth: 800)
            .render(Document(parsing: "```mermaid\n\(request.source)```\n"))
        #expect(out.string == "\u{FFFC}\n")
        #expect((out.attribute(MermaidBlock.key, at: 0, effectiveRange: nil) as? MermaidBlock)?.shownDark == false)
    }

    @Test @MainActor func syntaxErrorFails() async throws {
        try #require(MermaidRenderer.resources != nil, "mermaid.js is not in the build")
        let request = MermaidRenderer.Request(source: "graph TD\n  A[open --> B\n  B -->\n", dark: false, width: 800)
        let outcome = await withCheckedContinuation { c in MermaidRenderer.shared.render(request) { c.resume(returning: $0) } }
        guard case .failed(let message) = outcome else { Issue.record("drew a broken diagram"); return }
        #expect(message.lowercased().contains("error"))
        #expect(MermaidRenderer.shared.cached(request) == nil)
    }

    /// A diagram that lands above what is on screen must not move it.
    @Test @MainActor func placingADiagramKeepsTheTextInSight() async throws {
        try #require(MermaidRenderer.resources != nil, "mermaid.js is not in the build")
        let id = UUID().uuidString.prefix(8)
        let markdown = "```mermaid\ngraph TD\n  A[\(id)] --> B --> C --> D\n```\n\n"
            + (0..<300).map { "filler \($0) end\n\n" }.joined()
        let v = TextDocumentView()
        v.load(source: .text(markdown, title: "t"), kind: .markdown, theme: Theme(), preserveScroll: false)
        #expect(v.visibleOffset(of: "graph TD") != nil)      // code first
        v.scrollToPercent(50)
        let before = try #require(v.visibleOffset(of: "filler 150 end"))
        let top = v.scrollPosition.y
        for _ in 0..<400 where v.diagramsInFlight > 0 { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(v.diagramsInFlight == 0)
        #expect(v.visibleOffset(of: "graph TD") == nil)      // the diagram took its place
        #expect(v.scrollPosition.y != top)                   // taller than three lines of code
        let after = try #require(v.visibleOffset(of: "filler 150 end"))
        #expect(abs(after - before) < 1)
    }

    @Test func scalesAndFits() {
        let image = NSImage(size: NSSize(width: 400, height: 100))
        func size(width: CGFloat, scale: CGFloat) -> CGSize {
            let block = MermaidBlock(source: "", style: NSParagraphStyle(), width: width, scale: scale)
            let s = block.attributed(image, font: .systemFont(ofSize: 16))
            return (s.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment).bounds.size
        }
        #expect(size(width: 900, scale: 1) == CGSize(width: 400, height: 100))
        #expect(size(width: 900, scale: 1.5) == CGSize(width: 600, height: 150)) // follows the zoom
        #expect(size(width: 200, scale: 1) == CGSize(width: 200, height: 50))    // shrinks to the column
    }
}
