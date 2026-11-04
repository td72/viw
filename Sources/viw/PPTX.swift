import Foundation

/// PowerPoint (`.pptx`) → Markdown, one section per slide: the title placeholder as the heading,
/// body placeholders as bullet lists (`lvl` → nesting), text boxes as paragraphs, tables, pictures
/// (extracted to a temporary directory) and the speaker notes as a quote. Shapes, layout and
/// colours are not kept; SmartArt and charts leave a note.
enum PPTX {
    struct Result {
        var markdown: String
        /// Directory holding the extracted pictures (`ppt/media/…`); nil when there are none.
        var mediaDirectory: URL?
    }

    static func markdown(url: URL) throws -> Result {
        let zip = try ZipArchive(url: url)
        var c = Converter(zip: zip, source: url)
        for (i, part) in try slideParts(zip).enumerated() { c.slide(part, number: i + 1) }
        var md = c.out.joined(separator: "\n")
        while md.hasSuffix("\n") { md.removeLast() }
        return Result(markdown: md + "\n", mediaDirectory: c.mediaDirectory)
    }

    /// The slide parts (`ppt/slides/slide3.xml`) in presentation order: `p:sldIdLst` through the
    /// relationships (file numbers do not follow reordering); the file names, sorted, as a fallback.
    static func slideParts(_ zip: ZipArchive) throws -> [String] {
        guard let pres = XMLTree.parse(try zip.data(for: "ppt/presentation.xml")) else {
            throw ZipArchive.Error.badData("ppt/presentation.xml is not XML")
        }
        let rels = relationships(zip, of: "ppt/presentation.xml")
        let ordered = (pres["p:sldIdLst"]?.all("p:sldId") ?? [])
            .compactMap { $0.attributes["r:id"].flatMap { rels[$0] } }
        if !ordered.isEmpty { return ordered }
        return zip.entries.keys
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `Id` → target of a part's `.rels`, as a path inside the zip (`ppt/media/image1.png`) or a URL.
    static func relationships(_ zip: ZipArchive, of part: String) -> [String: String] {
        let dir = directory(of: part)
        let name = String(part.dropFirst(dir.count))
        guard let root = (try? zip.data(for: dir + "_rels/" + name + ".rels")).flatMap(XMLTree.parse) else { return [:] }
        var map: [String: String] = [:]
        for r in root.all("Relationship") {
            guard let id = r.attributes["Id"], let t = r.attributes["Target"] else { continue }
            let external = r.attributes["TargetMode"] == "External" || t.contains("://") || t.hasPrefix("mailto:")
            map[id] = external ? t : resolve(t, relativeTo: dir)
        }
        return map
    }

    /// `ppt/slides/` for `ppt/slides/slide1.xml`.
    static func directory(of part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "" }
        return String(part[...slash])
    }

    /// `../media/image1.png` next to `ppt/slides/` → `ppt/media/image1.png`.
    static func resolve(_ target: String, relativeTo dir: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = dir.split(separator: "/").map(String.init)
        for p in target.split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }

    struct Converter {
        let zip: ZipArchive
        let source: URL
        var out: [String] = []
        var mediaDirectory: URL?
        private var rels: [String: String] = [:]
        private var title: String?
        private var body: [String] = []
        /// Running numbers for `a:buAutoNum` paragraphs, per level; reset by any other paragraph.
        private var counters: [Int: Int] = [:]

        init(zip: ZipArchive, source: URL) { self.zip = zip; self.source = source }

        mutating func slide(_ part: String, number: Int) {
            if number > 1 { out.append("---"); out.append("") }
            title = nil
            body = []
            rels = PPTX.relationships(zip, of: part)
            guard let tree = (try? zip.data(for: part)).flatMap(XMLTree.parse)?["p:cSld"]?["p:spTree"] else {
                out.append("## Slide \(number)"); out.append(""); out.append("*(cannot read \(part))*"); out.append("")
                return
            }
            shapes(in: tree)
            out.append(title.map { "## Slide \(number): \($0)" } ?? "## Slide \(number)")
            out.append("")
            out += body
            if let notesPart = rels.values.first(where: { $0.contains("/notesSlides/") }), let lines = notes(in: notesPart), !lines.isEmpty {
                out.append("> **Notes**")
                out.append(">")
                for (i, l) in lines.enumerated() { // one quoted paragraph per note paragraph
                    if i > 0 { out.append(">") }
                    out.append("> " + l.replacingOccurrences(of: "\n", with: "\n> "))
                }
                out.append("")
            }
        }

        private mutating func shapes(in parent: XMLTree) {
            for node in parent.children {
                switch node.name {
                case "p:sp": shape(node)
                case "p:grpSp": shapes(in: node)
                case "p:pic": if let md = picture(node) { body.append(md); body.append("") }
                case "p:graphicFrame": graphicFrame(node)
                case "mc:AlternateContent": if let inner = node["mc:Fallback"] ?? node["mc:Choice"] { shapes(in: inner) }
                default: break
                }
            }
        }

        private mutating func shape(_ sp: XMLTree) {
            let ph = sp["p:nvSpPr"]?["p:nvPr"]?["p:ph"]
            let type = ph?.attributes["type"] ?? (ph != nil ? "body" : "")
            guard let txBody = sp["p:txBody"] else { return }
            switch type {
            case "sldNum", "dt", "ftr", "sldImg", "hdr": return // slide number, date, footer
            case "title", "ctrTitle":
                let t = paragraphs(in: txBody, bullets: false).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !t.isEmpty else { return }
                let text = t.joined(separator: " ").replacingOccurrences(of: "\\\n", with: " ")
                if title == nil { title = text } else { body.append("**\(text)**"); body.append("") }
            default:
                // Body / content placeholders bullet their paragraphs unless `a:buNone`; a text box does the opposite.
                let lines = paragraphs(in: txBody, bullets: type == "body" || type == "obj")
                guard !lines.isEmpty else { return }
                body += lines
                body.append("")
            }
        }

        /// One Markdown line per non-empty `a:p` (a list item with indentation when bulleted).
        private mutating func paragraphs(in txBody: XMLTree, bullets defaultBullets: Bool) -> [String] {
            var lines: [String] = []
            counters = [:]
            for p in txBody.all("a:p") {
                let text = inlines(in: p).trimmingCharacters(in: .whitespaces)
                let pPr = p["a:pPr"]
                let level = pPr?.attributes["lvl"].flatMap { Int($0) } ?? 0
                let indent = String(repeating: "  ", count: level)
                if text.isEmpty { continue }
                if pPr?["a:buAutoNum"] != nil {
                    let n = (counters[level] ?? 0) + 1
                    counters[level] = n
                    for deeper in counters.keys where deeper > level { counters[deeper] = nil }
                    lines.append("\(indent)\(n). \(text)")
                } else if pPr?["a:buNone"] == nil, defaultBullets || pPr?["a:buChar"] != nil || pPr?["a:buBlip"] != nil {
                    lines.append("\(indent)- \(text)")
                } else {
                    counters = [:]
                    lines.append(level > 0 ? indent + text : text)
                }
            }
            // Bulleted and plain lines alternate without blank lines; Markdown needs one before a list.
            var spaced: [String] = []
            for l in lines {
                let isItem = l.range(of: #"^\s*(- |\d+\. )"#, options: .regularExpression) != nil
                let prevItem = spaced.last.map { $0.range(of: #"^\s*(- |\d+\. )"#, options: .regularExpression) != nil } ?? isItem
                if isItem != prevItem { spaced.append("") }
                spaced.append(l)
            }
            return spaced
        }

        private mutating func inlines(in p: XMLTree) -> String {
            var s = ""
            for child in p.children {
                switch child.name {
                case "a:r", "a:fld": s += run(child)
                case "a:br": s += "\\\n"
                default: break
                }
            }
            return s
        }

        private mutating func run(_ r: XMLTree) -> String {
            let text = r["a:t"]?.text ?? ""
            let rPr = r["a:rPr"]
            let font = rPr?["a:latin"]?.attributes["typeface"]?.lowercased() ?? ""
            let mono = font.contains("courier") || font.contains("consolas") || font.contains("mono") || font.contains("menlo")
            let leading = text.prefix { $0 == " " }, trailing = text.reversed().prefix { $0 == " " }
            var core = String(text.dropFirst(leading.count).dropLast(trailing.count))
            if core.isEmpty { return text }
            if mono {
                core = "`" + core.replacingOccurrences(of: "`", with: "'") + "`"
            } else {
                core = DOCX.escape(core)
                if let b = rPr?.attributes["b"], b == "1" || b == "true" { core = "**\(core)**" }
                if let i = rPr?.attributes["i"], i == "1" || i == "true" { core = "*\(core)*" }
                if let strike = rPr?.attributes["strike"], strike != "noStrike" { core = "~~\(core)~~" }
            }
            if let id = rPr?["a:hlinkClick"]?.attributes["r:id"], let target = rels[id] { core = "[\(core)](\(target))" }
            return leading + core + trailing
        }

        private mutating func graphicFrame(_ frame: XMLTree) {
            guard let data = frame["a:graphic"]?["a:graphicData"] else { return }
            if let tbl = data["a:tbl"] { table(tbl); return }
            let uri = data.attributes["uri"] ?? ""
            if uri.hasSuffix("/chart") { body.append("*[chart]*"); body.append("") }
            else if uri.hasSuffix("/diagram") { body.append("*[SmartArt]*"); body.append("") }
        }

        private mutating func table(_ tbl: XMLTree) {
            var rows: [[String]] = []
            for tr in tbl.all("a:tr") {
                var cells: [String] = []
                for tc in tr.all("a:tc") {
                    if tc.attributes["hMerge"] == "1" || tc.attributes["vMerge"] == "1" { cells.append(""); continue }
                    let paras = (tc["a:txBody"]?.all("a:p") ?? []).map { inlines(in: $0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    cells.append(paras.joined(separator: " ").replacingOccurrences(of: "\\\n", with: " "))
                }
                rows.append(cells)
            }
            guard let width = rows.map(\.count).max(), width > 0 else { return }
            for i in rows.indices where rows[i].count < width { rows[i] += Array(repeating: "", count: width - rows[i].count) }
            body.append("| " + rows[0].joined(separator: " | ") + " |")
            body.append("|" + String(repeating: " --- |", count: width))
            for r in rows.dropFirst() { body.append("| " + r.joined(separator: " | ") + " |") }
            body.append("")
        }

        /// `![](…)` for a picture; the image file is extracted on first use.
        private mutating func picture(_ pic: XMLTree) -> String? {
            guard let id = pic["p:blipFill"]?["a:blip"]?.attributes["r:embed"], let entry = rels[id],
                  let data = try? zip.data(for: entry) else { return nil }
            if mediaDirectory == nil {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("viw-pptx-" + String(source.path.hashValue, radix: 36), isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                mediaDirectory = dir
            }
            guard let dir = mediaDirectory else { return nil }
            let name = (entry as NSString).lastPathComponent
            let file = dir.appendingPathComponent(name)
            try? data.write(to: file)
            let alt = pic["p:nvPicPr"]?["p:cNvPr"]?.attributes["descr"].flatMap { $0.isEmpty ? nil : $0 } ?? (name as NSString).deletingPathExtension
            return "![\(DOCX.escape(alt))](\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path))"
        }

        /// The speaker notes: the body placeholder's paragraphs (the slide image and number are skipped).
        private mutating func notes(in part: String) -> [String]? {
            guard let tree = (try? zip.data(for: part)).flatMap(XMLTree.parse)?["p:cSld"]?["p:spTree"] else { return nil }
            let saved = rels
            rels = PPTX.relationships(zip, of: part)
            defer { rels = saved }
            var lines: [String] = []
            for sp in tree.findAll("p:sp") {
                guard sp["p:nvSpPr"]?["p:nvPr"]?["p:ph"]?.attributes["type"] == "body", let txBody = sp["p:txBody"] else { continue }
                lines += paragraphs(in: txBody, bullets: false)
            }
            return lines
        }
    }
}
