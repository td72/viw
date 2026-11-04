import AppKit
import Foundation
import Markdown
import Testing
@testable import viw

@Suite struct JSONPrettyTests {
    @Test func keepsKeyOrderAndNumberSpelling() throws {
        let out = try #require(JSONPretty.format(#"{"b":1,"a":[1,2,{"c":null}],"n":1.50,"big":12345678901234567890}"#))
        let b = try #require(out.range(of: "\"b\""))
        let a = try #require(out.range(of: "\"a\""))
        #expect(b.lowerBound < a.lowerBound)
        #expect(out.contains("1.50"))                    // not re-serialised as 1.5
        #expect(out.contains("12345678901234567890"))    // not rounded through Double
        #expect(out.contains("null"))
        #expect(out.hasPrefix("{\n"))
    }

    @Test func invalidJSONIsNil() {
        #expect(JSONPretty.format("not json") == nil)
        #expect(JSONPretty.format("{\"a\": }") == nil)
    }

    @Test func jsonLines() {
        let lines = JSONPretty.formatLines("{\"a\":1}\nbroken\n\n{\"b\":[1,2]}\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"a\": 1"))
        #expect(lines[1] == "broken")                    // shown as written
        #expect(lines[2].contains("\"b\""))
    }
}

@Suite struct ZipArchiveTests {
    @Test func entriesAndData() throws {
        let zip = try ZipArchive(url: try fixture("mixed.zip"))
        #expect(zip.names == ["deflate.txt", "dir/日本語.txt", "empty.txt", "stored.txt"])
        #expect(zip.entries["stored.txt"]?.method == 0)
        #expect(zip.entries["deflate.txt"]?.method == 8)
        #expect(try zip.data(for: "stored.txt") == Data("stored bytes".utf8))
        #expect(try zip.data(for: "deflate.txt") == Data(String(repeating: "hello zip\n", count: 500).utf8))
        #expect(try zip.data(for: "dir/日本語.txt") == Data("こんにちは".utf8))
        #expect(try zip.data(for: "empty.txt").isEmpty)
        #expect(throws: ZipArchive.Error.self) { try zip.data(for: "missing.txt") }
    }

    @Test func corruptArchives() throws {
        let bad = try ZipArchive(url: try fixture("badcrc.zip"))
        #expect(throws: ZipArchive.Error.self) { try bad.data(for: "stored.txt") }
        #expect(try bad.data(for: "deflate.txt").count == 5000)     // the other entries are fine
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(url: try fixture("truncated.zip")) }
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(data: Data("PK but not a zip".utf8)) }
    }

    @Test func encryptedAndDates() throws {
        let zip = try ZipArchive(url: try fixture("encrypted.zip"))
        #expect(zip.entries["secret.txt"]?.encrypted == true)
        #expect(zip.entries["open.txt"]?.encrypted == false)
        #expect(throws: ZipArchive.Error.self) { try zip.data(for: "secret.txt") }
        #expect(try zip.data(for: "open.txt") == Data("open text\n".utf8))
        let when = try #require(zip.entries["open.txt"]?.modified)
        #expect(when > Date(timeIntervalSince1970: 1_700_000_000))      // a real date, not 1980
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: try #require(ZipArchive.dosDate(time: 0x7D7C, date: 0x5D63)))
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 11, 3, 15, 43, 56])
        #expect(ZipArchive.dosDate(time: 0, date: 0) == nil)
    }

    @Test func crc32() {
        #expect(ZipArchive.crc32(Data()) == 0)
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)  // the standard check value
    }
}

@Suite struct ConfigTests {
    @Test func parsesFlatToml() {
        let c = Config.parse("""
        # comment
        font = "Hiragino Sans"   # trailing comment
        code_font = 'JetBrains Mono'
        size = 15
        code-scale = 0.9
        max_width = 100000
        detail_pane = "Bottom"
        pdf_mode = "sideways"
        close_empty = "keep"
        [section]
        ignored = 1
        """)
        #expect(c.font == "Hiragino Sans")
        #expect(c.codeFont == "JetBrains Mono")
        #expect(c.size == 15)
        #expect(c.codeScale == 0.9)             // `-` and `_` are the same key
        #expect(c.maxWidth == 10_000)           // clamped
        #expect(c.detailPane == "bottom")
        #expect(c.pdfMode == nil)               // unknown value is dropped
        #expect(c.closeEmpty == "keep")
    }

    @Test func emptyAndOdd() {
        let c = Config.parse("font = \"\"\nsize = big\nfont = \"a # not a comment\"\n")
        #expect(c.font == "a # not a comment")
        #expect(c.size == nil)
    }
}

@Suite struct HighlighterTests {
    @Test func languageAliases() {
        #expect(Highlighter.language(for: "jsonl")?.tsName == "json")
        #expect(Highlighter.language(for: "Dockerfile")?.tsName == "dockerfile")
        #expect(Highlighter.language(for: "cxx")?.tsName == "cpp")
        #expect(Highlighter.language(for: "zsh")?.tsName == "bash")
        #expect(Highlighter.language(for: "c++ title=\"x\"")?.tsName == "cpp")
        #expect(Highlighter.language(for: "py")?.tsName == "python")
        #expect(Highlighter.language(for: "nope123") == nil)
        #expect(Highlighter.language(for: nil) == nil)
    }
}

@Suite struct FileKindTests {
    private func kind(_ name: String) -> FileKind { FileKind.of(URL(fileURLWithPath: "/x/" + name)) }

    @Test func byExtension() {
        #expect({ if case .markdown = kind("README.md") { return true } else { return false } }())
        #expect({ if case .markdown = kind("LICENSE") { return true } else { return false } }())
        #expect({ if case .code("Dockerfile") = kind("Dockerfile") { return true } else { return false } }())
        #expect({ if case .code("swift") = kind("a.swift") { return true } else { return false } }())
        #expect({ if case .json = kind("a.json") { return true } else { return false } }())
        #expect({ if case .json = kind("a.json5") { return true } else { return false } }())
        #expect({ if case .markdown = kind("a.mdwn") { return true } else { return false } }())
        #expect({ if case .code("jl") = kind("a.jl") { return true } else { return false } }())
        #expect({ if case .code("pl") = kind("a.pl") { return true } else { return false } }())
        #expect({ if case .code("ts") = kind("a.ts") { return true } else { return false } }())   // TypeScript, not MPEG-TS
        #expect({ if case .code("c++") = kind("a.c++") { return true } else { return false } }())
        #expect({ if case .code("xml") = kind("a.xml") { return true } else { return false } }())
        #expect({ if case .jsonl = kind("a.ndjson") { return true } else { return false } }())
        #expect({ if case .table = kind("a.tsv") { return true } else { return false } }())
        #expect({ if case .workbook = kind("a.XLSX") { return true } else { return false } }())
        #expect({ if case .database = kind("a.sqlite") { return true } else { return false } }())
        #expect({ if case .archive = kind("a.whl") { return true } else { return false } }())
        #expect({ if case .pdf = kind("a.pdf") { return true } else { return false } }())
        #expect({ if case .document = kind("a.docx") { return true } else { return false } }())
        #expect({ if case .document = kind("a.rtf") { return true } else { return false } }())
        #expect({ if case .document = kind("a.doc") { return true } else { return false } }())
        #expect({ if case .document = kind("a.odt") { return true } else { return false } }())
        #expect({ if case .notebook = kind("a.ipynb") { return true } else { return false } }())
        #expect({ if case .presentation = kind("a.pptx") { return true } else { return false } }())
        #expect({ if case .image = kind("a.webp") { return true } else { return false } }())
        #expect({ if case .image = kind("a.svg") { return true } else { return false } }())
        #expect({ if case .video = kind("a.mkv") { return true } else { return false } }())
        #expect({ if case .audio = kind("a.flac") { return true } else { return false } }())
        #expect({ if case .plain = kind("a.unknownext") { return true } else { return false } }())
        #expect(!kind("a.unknownext").isViewable)
    }
}

@Suite struct RendererTests {
    @Test func linkShowsItsTextNotTheURL() {
        let md = "See [Project page](https://github.com/td72/viw) and [](https://example.com).\n"
        let out = MarkdownRenderer(theme: Theme(), baseURL: nil).render(Markdown.Document(parsing: md)).string
        #expect(out.contains("See Project page and https://example.com."))
    }
}

@Suite struct RichDocumentTests {
    @Test func readsRtf() throws {
        let rtf = try RichDocument.read(url: try fixture("sample.rtf"))
        #expect(rtf.string.contains("Third point"))
        #expect(rtf.string.contains("日本語の段落"))
        var hasTable = false, hasBold = false
        rtf.enumerateAttributes(in: NSRange(location: 0, length: rtf.length), options: []) { attrs, _, _ in
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle, !p.textBlocks.isEmpty { hasTable = true }
            if let f = attrs[.font] as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) { hasBold = true }
        }
        #expect(hasTable && hasBold)
    }

    @Test func restyleKeepsAuthorColoursAndScalesFonts() {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "black ", attributes: [.foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 12), .backgroundColor: NSColor.white]))
        s.append(NSAttributedString(string: "red ", attributes: [.foregroundColor: NSColor.red, .font: NSFont.systemFont(ofSize: 8)]))
        s.append(NSAttributedString(string: "none", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        let out = RichDocument.restyle(s, text: .labelColor, scale: 1.5)
        #expect(out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(out.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(out.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == .red)
        #expect(out.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor == .labelColor)
        #expect((out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        #expect((out.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize == 12)
        #expect((out.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)?.pointSize == 36)
        #expect(RichDocument.luminance(of: .white) > 0.99 && RichDocument.luminance(of: .black) < 0.01)
    }
}

@Suite struct DOCXTests {
    @Test func convertsToMarkdown() throws {
        let r = try DOCX.markdown(url: try fixture("sample.docx"))
        let md = r.markdown
        #expect(md.contains("# viw sample document\n"))
        #expect(md.contains("# Lists\n"))          // Title and Heading 1 are both level 1
        #expect(md.contains("**bold**, *italic* and red text, plus 日本語の段落も混ぜてあります。"))
        #expect(md.contains("- First point\n- Second point\n- Third point"))
        #expect(md.contains("- Third point with a longer sentence to wrap in a narrow window.\n\n1. Step one\n2. Step two\n\n"))
        #expect(md.contains("| **Region** | **Units** | **Revenue** |\n| --- | --- | --- |\n| East | 120 | 18,000 |"))
        #expect(md.contains("[github.com/td72/viw](https://github.com/td72/viw)"))
        #expect(md.contains("> A quote paragraph."))
        #expect(md.contains("`print(\"hello\")`"))
        let dir = try #require(r.mediaDirectory)
        #expect(md.contains("![image1](" + (dir.appendingPathComponent("image1.png").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + ")"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("image1.png").path))
    }

    @Test func escapesMarkdownSyntax() throws {
        // A paragraph built by hand: text that would otherwise be read as Markdown.
        let xml = """
        <w:document xmlns:w="w"><w:body>
        <w:p><w:r><w:t>- not a list *nor emphasis* #tag &lt;b&gt;</w:t></w:r></w:p>
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">bold </w:t></w:r><w:r><w:t>plain</w:t><w:br/><w:t>next_line</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let root = try #require(XMLTree.parse(Data(xml.utf8)))
        var c = DOCX.Converter(zip: try ZipArchive(url: try fixture("mixed.zip")), source: URL(fileURLWithPath: "/x.docx"))
        c.blocks(in: try #require(root["w:body"]))
        let md = c.out.joined(separator: "\n")
        #expect(md.contains("\\- not a list \\*nor emphasis\\* \\#tag \\<b\\>"))
        #expect(md.contains("**bold** plain\\\nnext\\_line"))
    }
}

@Suite struct PPTXTests {
    @Test func convertsToMarkdown() throws {
        let r = try PPTX.markdown(url: try fixture("sample.pptx"))
        let md = r.markdown
        // Presentation order comes from p:sldIdLst (the title slide is slide10.xml).
        #expect(md.hasPrefix("## Slide 1: viw sample deck\n\nSlides as text — サブタイトル\n\n> **Notes**\n>\n> Speaker notes for the title slide.\n> Second line of notes.\n\n---\n\n## Slide 2: Agenda\n"))
        #expect(md.contains("- First point\n- Second point\n  - Nested under second\n    - Deeper still\n- Third point \\*with\\* markdown chars\n- 日本語の箇条書き\n"))
        #expect(md.contains("- **bold**, *italic* and `code` and ~~gone~~\n- [Project page](https://github.com/td72/viw)\n- line one\\\nline two after break\n- Shown on slide 3\n"))
        #expect(md.contains("| Region | Units | Revenue |\n| --- | --- | --- |\n| East | 120 | 18,000 |\n| West | 80 | 12,500 |\n| Total \\| all |  | 30,500 |\n"))
        #expect(md.contains("## Slide 5\n\n![A blue rectangle]("))                      // no title placeholder, alt from descr
        #expect(md.contains("A caption in a plain text box\n\n- Manual bullet\n"))   // text box: plain unless buChar
        #expect(md.contains("1. Install\n2. Open a file\n3. Press ?\n\nNo bullet here\n"))
        #expect(md.contains("## Slide 8: Grouped\n\nInside a group\n\nAlso grouped\n"))
        #expect(!md.contains("Footer text"))                                        // ftr / sldNum placeholders are skipped
        #expect(md.hasSuffix("## Slide 10\n\nLast slide, no title placeholder\n\n> **Notes**\n>\n> Final notes.\n"))
        #expect(md.components(separatedBy: "\n## Slide ").count == 10)
        let dir = try #require(r.mediaDirectory)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("image1.png").path))
    }

    @Test func pathsAndOrder() throws {
        #expect(PPTX.resolve("../media/image1.png", relativeTo: "ppt/slides/") == "ppt/media/image1.png")
        #expect(PPTX.resolve("/ppt/media/a.png", relativeTo: "ppt/slides/") == "ppt/media/a.png")
        #expect(PPTX.resolve("slides/slide1.xml", relativeTo: "ppt/") == "ppt/slides/slide1.xml")
        #expect(PPTX.directory(of: "ppt/slides/slide1.xml") == "ppt/slides/")
        #expect(try PPTX.slideParts(ZipArchive(url: try fixture("sample.pptx"))).prefix(2) == ["ppt/slides/slide10.xml", "ppt/slides/slide1.xml"])
        #expect(throws: (any Error).self) { try PPTX.markdown(url: try fixture("mixed.zip")) }
    }
}

@Suite struct NotebookTests {
    @Test func convertsToMarkdown() throws {
        let r = try Notebook.markdown(url: try fixture("sample.ipynb"))
        let md = r.markdown
        #expect(md.hasPrefix("# Sales analysis\n\nA **notebook** rendered by viw."))
        #expect(md.contains("`In [1]:`\n\n```python\nimport pandas as pd\ndf = pd.DataFrame"))
        #expect(md.contains("```python\ndf\n```\n\n```\n  region  units\n0   East    120\n1   West     95\n```"))  // text/plain wins over text/html
        #expect(md.contains("```\nEast 120\nWest 95\n```"))                                         // stream, trailing newline trimmed
        #expect(md.contains("```\n<Axes: >\n```"))
        let dir = try #require(r.mediaDirectory)
        #expect(md.contains("![output 1](" + (dir.appendingPathComponent("output-1.png").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + ")"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("output-1.png").path))
        #expect(md.contains("ZeroDivisionError: division by zero\n```"))
        #expect(!md.contains("\u{1B}"))                                                             // ANSI stripped
        #expect(md.contains("```\nraw cell, shown as written: *not* markdown\n```"))
        #expect(md.contains("`In [ ]:`\n\n```python\n\n```"))                                     // never-run empty cell
        #expect(md.hasSuffix("## Done\n\n| region | units |\n| --- | --- |\n| East | 120 |\n\n"))
    }

    @Test func oddInputs() throws {
        #expect(throws: Notebook.Error.self) { try Notebook.markdown(data: Data("{}".utf8), source: URL(fileURLWithPath: "/x.ipynb")) }
        #expect(throws: Notebook.Error.self) { try Notebook.markdown(data: Data("nope".utf8), source: URL(fileURLWithPath: "/x.ipynb")) }
        // No kernel metadata: plain fences. Backticks inside a cell widen the fence.
        let nb = #"{"cells":[{"cell_type":"code","source":"x = \"```\"","outputs":[]}],"metadata":{}}"#
        let md = try Notebook.markdown(data: Data(nb.utf8), source: URL(fileURLWithPath: "/x.ipynb")).markdown
        #expect(md.contains("````\nx = \"```\"\n````"))
        #expect(Notebook.stripANSI("\u{1B}[0;31mred\u{1B}[0m plain") == "red plain")
    }
}

@Suite struct SQLiteTests {
    @Test func tablesAndViews() throws {
        let db = try SQLiteDatabase(url: try fixture("sample.sqlite"))
        #expect(db.sheetNames == ["empty_table", "items", "regions", "stock"])   // tables then views, no indexes
        #expect(db.sheetNote(1) == "table · 4 rows")
        #expect(db.sheetNote(0) == "table · 0 rows")
        #expect(db.sheetNote(3) == "view")
        let items = try db.table(forSheet: 1)
        #expect(items.header == ["id", "name", "price", "qty", "note", "data", "added"])
        #expect(items.rows[0] == ["1", "apple", "120.5", "3", "fresh", "<blob 4 bytes>", "2026-10-01"])
        #expect(items.rows[1] == ["2", "pear", "95", "0", "", "", "2026-10-02"])              // NULLs empty
        #expect(items.rows[2][1] == "りんご" && items.rows[2][2] == "1234567.891" && items.rows[2][5] == "<blob 1 byte>")
        #expect(items.rows[3][2] == "1.500000E-05" && items.rows[3][3] == "-1" && items.rows[3][5] == "<blob 0 bytes>")
        #expect(items.totalRows == 5 && !items.truncated)
        #expect(items.types == [.integer, .text, .number, .integer, .text, .text, .date])
        let regions = try db.table(forSheet: 2)
        #expect(regions.header[0] == "region name")
        let stock = try db.table(forSheet: 3)
        #expect(stock.header == ["name", "qty", "value"])
        #expect(stock.rows.map { $0[0] } == ["apple", "りんご"])
        #expect(try db.table(forSheet: 0).rows.isEmpty)
    }

    @Test func detection() throws {
        #expect(SQLiteDatabase.isDatabase(try fixture("sample.sqlite")))
        #expect(!SQLiteDatabase.isDatabase(try fixture("mixed.zip")))
        #expect(throws: SQLiteDatabase.Error.self) { try SQLiteDatabase(url: try fixture("mixed.zip")) }
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("viw-fake-\(getpid()).db")
        try Data("not a database".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }
        #expect({ if case .plain = FileKind.of(fake) { return true } else { return false } }())
        #expect(SQLiteDatabase.quote("a\"b") == "\"a\"\"b\"")
    }
}

@Suite struct ArchiveBrowserTests {
    @Test func treePreviewAndExtraction() throws {
        let a = try ArchiveBrowser(url: try fixture("mixed.zip"))
        let root = a.root
        #expect(root.children.map(\.name) == ["dir", "deflate.txt", "empty.txt", "stored.txt"])   // folders first
        let dir = root.children[0]
        #expect(dir.isDirectory && dir.path == "dir/" && dir.entry == nil)                       // implied by its file
        #expect(dir.children.map(\.path) == ["dir/日本語.txt"])
        #expect(dir.children[0].ancestors.map(\.path) == ["dir/"] && dir.ancestors.isEmpty && dir.children[0].parent === dir)
        #expect(dir.fileCount == 1 && dir.size == 15)
        #expect(a.entryCount == 4 && a.totalSize == 5000 + 15 + 0 + 12)
        #expect(root.descendants.map(\.path) == ["dir/", "dir/日本語.txt", "deflate.txt", "empty.txt", "stored.txt"])
        let stored = root.children[3], deflate = root.children[1], empty = root.children[2]
        #expect(stored.entry?.method == 0 && stored.size == 12)
        #expect(a.preview(stored) == "stored bytes")
        #expect(a.preview(dir.children[0]) == "こんにちは")
        #expect(a.preview(deflate)?.hasSuffix("\n…") == true)                                   // longer than the preview window
        #expect(a.preview(empty) == "")
        #expect(a.preview(dir) == nil)
        let url = try a.extract(dir.children[0])
        #expect(url.lastPathComponent == "日本語.txt" && url.deletingLastPathComponent().lastPathComponent == "dir")
        #expect(try String(contentsOf: url, encoding: .utf8) == "こんにちは")
        #expect(throws: ZipArchive.Error.self) { try a.extract(dir) }
    }

    @Test func binaryEncryptedAndFolders() throws {
        let enc = try ArchiveBrowser(url: try fixture("encrypted.zip"))
        let secret = try #require(enc.root.children.first { $0.name == "secret.txt" })
        #expect(secret.entry?.encrypted == true)
        #expect(enc.preview(secret) == nil)
        #expect(throws: ZipArchive.Error.self) { try enc.extract(secret) }
        let bad = try ArchiveBrowser(url: try fixture("badcrc.zip"))
        #expect(enc.root.children.count == 2 && bad.preview(bad.root.children.first { $0.name == "stored.txt" }!) == nil)  // CRC mismatch: nothing shown
        #expect(ArchiveDocumentView.bytes(0) == "Zero bytes" || ArchiveDocumentView.bytes(0) == "0 bytes")
        #expect(ArchiveDocumentView.bytes(20480) == "20 KB")
    }
}
