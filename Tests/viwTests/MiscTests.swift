import AppKit
import Foundation
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
        #expect({ if case .pdf = kind("a.pdf") { return true } else { return false } }())
        #expect({ if case .document = kind("a.docx") { return true } else { return false } }())
        #expect({ if case .document = kind("a.rtf") { return true } else { return false } }())
        #expect({ if case .document = kind("a.doc") { return true } else { return false } }())
        #expect({ if case .document = kind("a.odt") { return true } else { return false } }())
        #expect({ if case .image = kind("a.webp") { return true } else { return false } }())
        #expect({ if case .image = kind("a.svg") { return true } else { return false } }())
        #expect({ if case .video = kind("a.mkv") { return true } else { return false } }())
        #expect({ if case .audio = kind("a.flac") { return true } else { return false } }())
        #expect({ if case .plain = kind("a.unknownext") { return true } else { return false } }())
        #expect(!kind("a.unknownext").isViewable)
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
