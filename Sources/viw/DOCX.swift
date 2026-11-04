import Foundation

/// Word documents, converted to Markdown and rendered like a `.md` file. AppKit's own docx
/// importer flattens styles (every heading comes out as 12 pt body text) and drops hyperlinks,
/// so the body is read from the OOXML directly: headings, bold / italic / strikethrough, code
/// (monospace runs), lists (bullet or numbered from numbering.xml), tables, hyperlinks, pictures
/// (extracted next to a temporary directory the Markdown refers to), block quotes, breaks.
enum DOCX {
    struct Result {
        var markdown: String
        /// Directory holding the extracted pictures (`word/media/…`); nil when there are none.
        var mediaDirectory: URL?
    }

    static func markdown(url: URL) throws -> Result {
        let zip = try ZipArchive(url: url)
        guard let body = try XMLTree.parse(zip.data(for: "word/document.xml"))?["w:body"] else {
            throw ZipArchive.Error.badData("word/document.xml has no body")
        }
        var c = Converter(zip: zip, source: url)
        c.styles = Styles(zip: zip)
        c.numbering = Numbering(zip: zip)
        c.relationships = (try? zip.data(for: "word/_rels/document.xml.rels")).flatMap(XMLTree.parse).map(relationships) ?? [:]
        c.blocks(in: body)
        var md = c.out.joined(separator: "\n")
        while md.hasSuffix("\n") { md.removeLast() }
        return Result(markdown: md + "\n", mediaDirectory: c.mediaDirectory)
    }

    /// Markdown-escaped text (also used by the pptx converter).
    static func escape(_ s: String) -> String { Converter.escape(s) }

    /// `Id` → `Target` (URLs for hyperlinks, `media/image1.png` for pictures).
    static func relationships(_ root: XMLTree) -> [String: String] {
        var map: [String: String] = [:]
        for r in root.all("Relationship") { if let id = r.attributes["Id"], let t = r.attributes["Target"] { map[id] = t } }
        return map
    }

    /// styles.xml: style id → heading level (Title = 1, Heading N = N) and quote styles.
    struct Styles {
        var heading: [String: Int] = [:]
        var quote: Set<String> = []
        var code: Set<String> = []
        /// Styles that are lists themselves ("List Bullet", "List Number"): numId and level.
        var list: [String: (numId: String, level: Int)] = [:]

        init() {}
        init(zip: ZipArchive) {
            guard let root = (try? zip.data(for: "word/styles.xml")).flatMap(XMLTree.parse) else { return }
            for s in root.all("w:style") where s.attributes["w:type"] == "paragraph" {
                guard let id = s.attributes["w:styleId"] else { continue }
                let name = (s["w:name"]?.attributes["w:val"] ?? id).lowercased()
                if let numPr = s["w:pPr"]?["w:numPr"], let numId = numPr["w:numId"]?.attributes["w:val"] {
                    list[id] = (numId, numPr["w:ilvl"]?.attributes["w:val"].flatMap { Int($0) } ?? 0)
                }
                if name == "title" { heading[id] = 1 }
                else if let n = name.range(of: #"^heading ?(\d)$"#, options: .regularExpression).map({ Int(name[$0].filter(\.isNumber)) ?? 0 }), n > 0 { heading[id] = n }
                else if let lvl = s["w:pPr"]?["w:outlineLvl"]?.attributes["w:val"].flatMap({ Int($0) }) { heading[id] = lvl + 1 }
                else if name.contains("quote") { quote.insert(id) }
                else if name.contains("code") || name == "htmlpreformatted" || name == "plain text" { code.insert(id) }
            }
        }
    }

    /// numbering.xml: numId + level → bullet or ordered.
    struct Numbering {
        private var abstractFormats: [String: [Int: String]] = [:] // abstractNumId → ilvl → numFmt
        private var numToAbstract: [String: String] = [:]

        init() {}
        init(zip: ZipArchive) {
            guard let root = (try? zip.data(for: "word/numbering.xml")).flatMap(XMLTree.parse) else { return }
            for a in root.all("w:abstractNum") {
                guard let id = a.attributes["w:abstractNumId"] else { continue }
                var levels: [Int: String] = [:]
                for l in a.all("w:lvl") {
                    if let i = l.attributes["w:ilvl"].flatMap({ Int($0) }) { levels[i] = l["w:numFmt"]?.attributes["w:val"] ?? "decimal" }
                }
                abstractFormats[id] = levels
            }
            for n in root.all("w:num") {
                if let id = n.attributes["w:numId"], let a = n["w:abstractNumId"]?.attributes["w:val"] { numToAbstract[id] = a }
            }
        }

        func isBullet(numId: String, level: Int) -> Bool {
            guard let a = numToAbstract[numId], let fmt = abstractFormats[a]?[level] else { return true }
            return fmt == "bullet" || fmt == "none"
        }
    }

    struct Converter {
        let zip: ZipArchive
        let source: URL
        var styles = Styles()
        var numbering = Numbering()
        var relationships: [String: String] = [:]
        var out: [String] = []
        var mediaDirectory: URL?
        /// Running counters for numbered lists (numId + level → next number), reset when a list ends.
        private var counters: [String: Int] = [:]
        /// numId of the list the previous paragraph belonged to, so a change of list (or its end) gets a blank line.
        private var listID: String?

        init(zip: ZipArchive, source: URL) { self.zip = zip; self.source = source }

        mutating func blocks(in parent: XMLTree) {
            for node in parent.children {
                switch node.name {
                case "w:p": paragraph(node)
                case "w:tbl": table(node)
                case "w:sdt": if let content = node["w:sdtContent"] { blocks(in: content) }
                case "w:sectPr", "w:bookmarkStart", "w:bookmarkEnd": break
                default: if node.find("w:p") != nil { blocks(in: node) }
                }
            }
        }

        private mutating func paragraph(_ p: XMLTree) {
            let pPr = p["w:pPr"]
            let styleId = pPr?["w:pStyle"]?.attributes["w:val"] ?? ""
            let text = inlines(in: p)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let numPr = pPr?["w:numPr"]
            if let numId = numPr?["w:numId"]?.attributes["w:val"] ?? styles.list[styleId]?.numId {
                let level = numPr?["w:ilvl"]?.attributes["w:val"].flatMap { Int($0) } ?? styles.list[styleId]?.level ?? 0
                if listID != numId { if listID != nil { out.append("") }; listID = numId }
                let indent = String(repeating: "  ", count: level)
                if numbering.isBullet(numId: numId, level: level) {
                    out.append("\(indent)- \(trimmed)")
                } else {
                    let key = "\(numId)/\(level)"
                    let n = (counters[key] ?? 0) + 1
                    counters[key] = n
                    out.append("\(indent)\(n). \(trimmed)")
                }
                return
            }
            counters = [:]
            if listID != nil { out.append(""); listID = nil }
            if trimmed.isEmpty { if out.last != "" { out.append("") }; return }
            if let level = styles.heading[styleId] {
                out.append("")
                out.append(String(repeating: "#", count: min(level, 6)) + " " + trimmed)
                out.append("")
            } else if styles.quote.contains(styleId) {
                out.append("> " + trimmed.replacingOccurrences(of: "\n", with: "\n> "))
                out.append("")
            } else if styles.code.contains(styleId) {
                out.append("```\n" + plainText(in: p) + "\n```")
                out.append("")
            } else {
                out.append(trimmed)
                out.append("")
            }
        }

        private mutating func table(_ tbl: XMLTree) {
            if listID != nil { out.append(""); listID = nil }
            var rows: [[String]] = []
            for tr in tbl.all("w:tr") {
                var cells: [String] = []
                for tc in tr.all("w:tc") {
                    let paras = tc.all("w:p").map { inlines(in: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let cell = paras.joined(separator: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                    cells.append(cell)
                    if let span = tc["w:tcPr"]?["w:gridSpan"]?.attributes["w:val"].flatMap({ Int($0) }), span > 1 {
                        cells += Array(repeating: "", count: span - 1)
                    }
                }
                rows.append(cells)
            }
            guard let width = rows.map(\.count).max(), width > 0 else { return }
            for i in rows.indices where rows[i].count < width { rows[i] += Array(repeating: "", count: width - rows[i].count) }
            out.append("")
            out.append("| " + rows[0].joined(separator: " | ") + " |")
            out.append("|" + String(repeating: " --- |", count: width))
            for r in rows.dropFirst() { out.append("| " + r.joined(separator: " | ") + " |") }
            out.append("")
        }

        /// Markdown for the runs of a paragraph (also used for table cells and list items).
        private mutating func inlines(in node: XMLTree) -> String {
            var s = ""
            for child in node.children {
                switch child.name {
                case "w:r": s += run(child)
                case "w:hyperlink":
                    let inner = inlines(in: child)
                    if let id = child.attributes["r:id"], let target = relationships[id] {
                        s += "[\(inner)](\(target))"
                    } else if let anchor = child.attributes["w:anchor"] {
                        s += "[\(inner)](#\(anchor))"
                    } else {
                        s += inner
                    }
                case "w:ins", "w:smartTag", "w:sdt", "w:sdtContent", "w:fldSimple": s += inlines(in: child)
                case "w:del", "w:pPr", "w:proofErr", "w:bookmarkStart", "w:bookmarkEnd": break
                default: s += inlines(in: child)
                }
            }
            return s
        }

        private mutating func run(_ r: XMLTree) -> String {
            let rPr = r["w:rPr"]
            let br = "\u{1}" // stands in for a line break until the text has been escaped
            var text = "", pictures = ""
            for child in r.children {
                switch child.name {
                case "w:t": text += child.text
                case "w:tab": text += "    "
                case "w:br", "w:cr": text += br
                case "w:noBreakHyphen": text += "-"
                case "w:softHyphen": break
                case "w:sym": if let ch = child.attributes["w:char"].flatMap({ UInt32($0, radix: 16) }).flatMap(UnicodeScalar.init) { text += String(ch) }
                case "w:drawing", "w:pict": pictures += picture(in: child)
                default: break
                }
            }
            guard !text.trimmingCharacters(in: CharacterSet(charactersIn: " " + br)).isEmpty else {
                return text.replacingOccurrences(of: br, with: "\\\n") + pictures
            }
            let font = rPr?["w:rFonts"]?.attributes["w:ascii"]?.lowercased() ?? ""
            let mono = font.contains("courier") || font.contains("consolas") || font.contains("mono") || font.contains("menlo")
            if mono { return "`" + text.replacingOccurrences(of: "`", with: "'") + "`" }
            let leading = text.prefix { $0 == " " }, trailing = text.reversed().prefix { $0 == " " }
            var core = Self.escape(String(text.dropFirst(leading.count).dropLast(trailing.count)))
            if core.isEmpty { return text }
            if rPr?["w:b"] != nil, rPr?["w:b"]?.attributes["w:val"] != "0", rPr?["w:b"]?.attributes["w:val"] != "false" { core = "**\(core)**" }
            if rPr?["w:i"] != nil, rPr?["w:i"]?.attributes["w:val"] != "0", rPr?["w:i"]?.attributes["w:val"] != "false" { core = "*\(core)*" }
            if rPr?["w:strike"] != nil || rPr?["w:dstrike"] != nil { core = "~~\(core)~~" }
            return (leading + core + trailing).replacingOccurrences(of: br, with: "\\\n") + pictures
        }

        /// Text of a paragraph without any Markdown (code blocks).
        private func plainText(in p: XMLTree) -> String {
            p.findAll("w:t").map(\.text).joined() + (p.findAll("w:br").isEmpty ? "" : "")
        }

        /// `![](…)` for the first picture in a drawing; the image file is extracted on first use.
        private mutating func picture(in drawing: XMLTree) -> String {
            guard let blip = drawing.find("a:blip"), let id = blip.attributes["r:embed"], let target = relationships[id] else {
                return drawing.find("v:imagedata")?.attributes["r:id"].flatMap { relationships[$0] }.flatMap { extract($0) } ?? ""
            }
            return extract(target) ?? ""
        }

        private mutating func extract(_ target: String) -> String? {
            let entry = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
            guard let data = try? zip.data(for: entry) else { return nil }
            if mediaDirectory == nil {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("viw-docx-" + String(source.path.hashValue, radix: 36), isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                mediaDirectory = dir
            }
            guard let dir = mediaDirectory else { return nil }
            let name = (target as NSString).lastPathComponent
            let file = dir.appendingPathComponent(name)
            try? data.write(to: file)
            let alt = (name as NSString).deletingPathExtension
            return "![\(alt)](\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path))"
        }

        fileprivate static func escape(_ s: String) -> String {
            var out = ""
            for ch in s {
                if "\\*_`[]<>~#|".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            // A line that starts like a list, heading or rule would become one.
            if let first = out.first, "-+".contains(first), out.dropFirst().first == " " { out = "\\" + out }
            if out.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil { out = out.replacingOccurrences(of: #"^(\d+)([.)])"#, with: "$1\\\\$2", options: .regularExpression) }
            return out
        }
    }
}
