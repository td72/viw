import AppKit
import Testing
@testable import viw

@Suite struct TOCTests {
    private func build(_ headings: [(Int, String)]) -> (all: [TOCHeading], roots: [TOCHeading]) {
        TOC.build(headings.map { HeadingMark(level: $0.0, title: $0.1) })
    }

    @Test func levelsMakeTheTree() {
        let t = build([(1, "A"), (2, "A1"), (3, "A1a"), (2, "A2"), (4, "deep"), (1, "B"), (3, "skips a level")])
        #expect(t.all.map(\.title) == ["A", "A1", "A1a", "A2", "deep", "B", "skips a level"])
        #expect(t.roots.map(\.title) == ["A", "B"])
        #expect(t.roots[0].children.map(\.title) == ["A1", "A2"])
        #expect(t.roots[0].children[0].children.map(\.title) == ["A1a"])
        #expect(t.roots[0].children[1].children.map(\.title) == ["deep"])
        #expect(t.roots[1].children.map(\.title) == ["skips a level"])
        #expect(t.all[4].parent === t.all[3])
        #expect(t.all[0].parent == nil)
    }

    @Test func aDocumentNeedNotStartAtLevelOne() {
        let t = build([(3, "first"), (2, "second"), (3, "under second")])
        #expect(t.roots.map(\.title) == ["first", "second"])
        #expect(t.roots[1].children.map(\.title) == ["under second"])
    }

    @Test func slugsFollowGitHub() {
        #expect(TOC.slug("Hello, World!") == "hello-world")
        #expect(TOC.slug("Install & run (macOS)") == "install--run-macos")
        #expect(TOC.slug("snake_case and kebab-case") == "snake_case-and-kebab-case")
        #expect(TOC.slug("日本語の 見出し 2") == "日本語の-見出し-2")
        let t = build([(1, "Setup"), (2, "Usage"), (2, "Setup"), (2, "Setup")])
        #expect(t.all.map(\.slug) == ["setup", "usage", "setup-1", "setup-2"])
    }

    @Test func fragmentsFindTheirHeading() {
        let t = build([(1, "Getting started"), (2, "FAQ: what & why?"), (2, "Getting started")])
        #expect(TOC.heading(for: "getting-started", in: t.all) === t.all[0])
        #expect(TOC.heading(for: "getting-started-1", in: t.all) === t.all[2])
        #expect(TOC.heading(for: "Getting-Started", in: t.all) === t.all[0])
        #expect(TOC.heading(for: "faq-what-why", in: t.all) === t.all[1])   // written by hand, a little off
        #expect(TOC.heading(for: "nowhere", in: t.all) == nil)
    }
}

@Suite @MainActor struct TextHeadingTests {
    private func view(_ markdown: String) -> TextDocumentView {
        let v = TextDocumentView()
        v.load(source: .text(markdown, title: "t"), kind: .markdown, theme: Theme(), preserveScroll: false)
        return v
    }

    private static let filler = String(repeating: "filler paragraph\n\n", count: 80)

    @Test func headingsAreReadFromTheRenderedText() {
        let v = view("# One *two* `three`\n\ntext\n\n## Inner\n\n> ### In a quote\n\n```\n# not a heading\n```\n\n#\n")
        #expect(v.headingTitles == ["One two three", "Inner", "In a quote"])
        v.load(source: .text("no headings\n", title: "t"), kind: .markdown, theme: Theme(), preserveScroll: false)
        #expect(v.headingTitles.isEmpty)
    }

    @Test func bracketsMoveByHeading() {
        let v = view("# A\n\n\(Self.filler)## B\n\n\(Self.filler)## C\n\n\(Self.filler)## D\n\n\(Self.filler)")
        #expect(v.headingMotions)
        v.moveHeading(1)                    // ]] from the top: past A, which is already in sight, to B
        let b = v.scrollPosition.y
        #expect(b > 0)
        v.moveHeading(2)                    // 2]]
        let d = v.scrollPosition.y
        #expect(d > b)
        v.moveHeading(1)                    // nothing after D
        #expect(v.scrollPosition.y == d)
        v.moveHeading(-1)                   // [[
        let c = v.scrollPosition.y
        #expect(c > b && c < d)
        v.scrollLines(3)                    // reading on inside C: [[ goes back to its heading
        v.moveHeading(-1)
        #expect(v.scrollPosition.y == c)
        v.moveHeading(-9)
        #expect(v.scrollPosition.y < b)
    }
}
