import AppKit

/// draw.io / diagrams.net files (`.drawio`, `.dio`): the `mxGraphModel` of every page, read with
/// Foundation only (a compressed page is base64 → raw deflate → URL-decoded XML), and a Core
/// Graphics rendering of the common shapes. Rectangles (rounded), ellipses, rhombi, triangles,
/// hexagons, parallelograms, cylinders, documents, notes, processes, clouds, swimlanes, tables,
/// text, images and groups are drawn as draw.io draws them; any other shape (the icon libraries,
/// stencils) falls back to a box with the label, so the diagram keeps its layout. Edges follow
/// their waypoints (orthogonal, straight or curved) with the usual arrow heads and labels.
enum Drawio {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    /// One `<diagram>` (a page of the file).
    struct Page {
        var name: String
        /// `background` of the model, when set; nil means the viewer's own background.
        var background: NSColor?
        /// Every cell by id (layers and invisible cells included).
        var cells: [String: Cell]
        /// Layers (children of the root cell "0") in order.
        var layers: [Cell]
    }

    /// An `mxCell`; `children` keep the file order. Geometry is relative to the parent (vertices)
    /// or in the parent's coordinate space (edge waypoints), as in the file.
    final class Cell {
        let id: String
        /// The label as text (HTML stripped when the cell has `html=1`).
        var label: String
        /// The HTML source of the label, for bold / italic / underline runs; nil for plain labels.
        var html: String?
        var style: Style
        var isVertex = false
        var isEdge = false
        var parent: String?
        var source: String?
        var target: String?
        var geometry = CGRect.zero
        var relative = false
        var points: [CGPoint] = []
        var sourcePoint: CGPoint?
        var targetPoint: CGPoint?
        var offset = CGPoint.zero
        var visible = true
        var collapsed = false
        var children: [Cell] = []

        init(id: String, label: String, style: Style) {
            self.id = id
            self.label = label
            self.style = style
        }
    }

    /// `rounded=1;whiteSpace=wrap;fillColor=#dae8fc;` → keys and values; a bare first token
    /// (`ellipse`, `swimlane`, `text`) is the shape unless `shape=` says otherwise.
    struct Style {
        var values: [String: String] = [:]
        var shape: String?

        init(_ s: String) {
            for (i, token) in s.split(separator: ";").enumerated() {
                if let eq = token.firstIndex(of: "=") {
                    values[String(token[..<eq])] = String(token[token.index(after: eq)...])
                } else if i == 0, !token.isEmpty {
                    shape = String(token)
                }
            }
            if let s = values["shape"] { shape = s }
        }

        subscript(_ key: String) -> String? { values[key] }
        func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
            values[key].flatMap { Double($0) }.map { CGFloat($0) } ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool = false) -> Bool {
            guard let v = values[key] else { return fallback }
            return v != "0" && v != "false"
        }
    }

    // MARK: - Parsing

    static func parse(url: URL) throws -> [Page] {
        try parse(data: try Data(contentsOf: url))
    }

    static func parse(data: Data) throws -> [Page] {
        guard let root = XMLTree.parse(data) else { throw Error(description: "not an XML file") }
        if root.name == "mxGraphModel" { return [page(from: root, name: "")] }
        guard root.name == "mxfile" else { throw Error(description: "not a draw.io file (root <\(root.name)>)") }
        var pages: [Page] = []
        for (i, d) in root.all("diagram").enumerated() {
            let name = d.attributes["name"] ?? "Page \(i + 1)"
            if let model = d["mxGraphModel"] {
                pages.append(page(from: model, name: name))
            } else if let model = decode(d.text).flatMap(XMLTree.parse), model.name == "mxGraphModel" {
                pages.append(page(from: model, name: name))
            } else {
                throw Error(description: "cannot decode page \"\(name)\"")
            }
        }
        if pages.isEmpty { throw Error(description: "no pages") }
        return pages
    }

    /// A compressed page: base64 of the raw-deflated, URL-encoded XML.
    static func decode(_ text: String) -> Data? {
        let trimmed = text.filter { !$0.isWhitespace }
        guard !trimmed.isEmpty, let deflated = Data(base64Encoded: trimmed),
              let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data,
              let encoded = String(data: inflated, encoding: .utf8) else { return nil }
        return (encoded.removingPercentEncoding ?? encoded).data(using: .utf8)
    }

    private static func page(from model: XMLTree, name: String) -> Page {
        var cells: [String: Cell] = [:]
        var order: [Cell] = []
        for node in model["root"]?.children ?? [] {
            // `<object label=… id=…><mxCell …/></object>` (and UserObject) wrap a cell with extra attributes.
            let wrapper: XMLTree? = node.name == "mxCell" ? nil : node
            guard let mx = wrapper == nil ? node : node["mxCell"] else { continue }
            let id = wrapper?.attributes["id"] ?? mx.attributes["id"] ?? "cell\(order.count)"
            let style = Style(mx.attributes["style"] ?? "")
            let raw = wrapper?.attributes["label"] ?? mx.attributes["value"] ?? ""
            let cell = Cell(id: id, label: style.flag("html") ? Label.text(fromHTML: raw) : raw, style: style)
            if style.flag("html"), raw.contains("<") { cell.html = raw }
            cell.isVertex = mx.attributes["vertex"] == "1"
            cell.isEdge = mx.attributes["edge"] == "1"
            cell.parent = mx.attributes["parent"]
            cell.source = mx.attributes["source"]
            cell.target = mx.attributes["target"]
            cell.visible = mx.attributes["visible"] != "0"
            cell.collapsed = mx.attributes["collapsed"] == "1"
            if let g = mx["mxGeometry"] {
                cell.geometry = CGRect(x: num(g, "x"), y: num(g, "y"), width: num(g, "width"), height: num(g, "height"))
                cell.relative = g.attributes["relative"] == "1"
                for p in g.children {
                    switch (p.name, p.attributes["as"]) {
                    case ("Array", "points"): cell.points = p.all("mxPoint").map { CGPoint(x: num($0, "x"), y: num($0, "y")) }
                    case ("mxPoint", "sourcePoint"): cell.sourcePoint = CGPoint(x: num(p, "x"), y: num(p, "y"))
                    case ("mxPoint", "targetPoint"): cell.targetPoint = CGPoint(x: num(p, "x"), y: num(p, "y"))
                    case ("mxPoint", "offset"): cell.offset = CGPoint(x: num(p, "x"), y: num(p, "y"))
                    default: break
                    }
                }
            }
            cells[id] = cell
            order.append(cell)
        }
        var layers: [Cell] = []
        for c in order {
            if let p = c.parent, p != "0", let parent = cells[p] { parent.children.append(c) } else if c.parent == "0" { layers.append(c) }
        }
        var background: NSColor?
        if let bg = model.attributes["background"], bg != "none", bg != "default" { background = color(bg) }
        return Page(name: name, background: background, cells: cells, layers: layers)
    }

    private static func num(_ t: XMLTree, _ key: String) -> CGFloat {
        t.attributes[key].flatMap { Double($0) }.map { CGFloat($0) } ?? 0
    }

    /// `#rrggbb` / `#rrggbbaa` / a CSS name; nil for "none" and anything unreadable.
    static func color(_ s: String) -> NSColor? {
        let s = s.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let a: CGFloat = hex.count == 8 ? CGFloat(v & 0xff) / 255 : 1
            let rgb = hex.count == 8 ? v >> 8 : v
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: a)
        }
        let named: [String: NSColor] = [
            "white": .white, "black": .black, "red": .red, "green": .green, "blue": .blue, "yellow": .yellow,
            "orange": .orange, "gray": .gray, "grey": .gray, "purple": .purple, "cyan": .cyan, "magenta": .magenta, "brown": .brown,
        ]
        return named[s]
    }

    /// Relative luminance (0 … 1) of a colour, for picking black or white text over it.
    static func luminance(_ c: NSColor) -> CGFloat {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    // MARK: - Labels

    enum Label {
        struct Run: Equatable {
            var text: String
            var bold = false
            var italic = false
            var underline = false
        }

        /// draw.io labels with `html=1` are HTML fragments: the text with the line breaks kept.
        static func text(fromHTML html: String) -> String {
            runs(fromHTML: html).map(\.text).joined()
        }

        /// The label split where `<b>` / `<i>` / `<u>` (and strong / em) start or stop; `<br>` and
        /// block tags (`div`, `p`, `li`, …) become newlines, entities are decoded.
        static func runs(fromHTML html: String) -> [Run] {
            var runs: [Run] = []
            var current = Run(text: "")
            var bold = 0, italic = 0, underline = 0
            var pendingBreak = false
            func flush() {
                if !current.text.isEmpty { runs.append(current) }
                current = Run(text: "", bold: bold > 0, italic: italic > 0, underline: underline > 0)
            }
            func newline() {
                while current.text.hasSuffix(" ") { current.text.removeLast() } // trailing blanks before a break are invisible in HTML
                current.text += "\n"
            }
            func emit(_ t: String) {
                if pendingBreak { newline(); pendingBreak = false }
                if t == "\n" { newline() } else { current.text += t }
            }
            var i = html.startIndex
            while i < html.endIndex {
                let c = html[i]
                if c == "<", let close = html[i...].firstIndex(of: ">") {
                    let tag = html[html.index(after: i)..<close].trimmingCharacters(in: .whitespaces).lowercased()
                    let closing = tag.hasPrefix("/")
                    let name = tag.drop { $0 == "/" }.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" }).first.map(String.init) ?? ""
                    let delta = closing ? -1 : 1
                    switch name {
                    case "br": emit("\n")
                    case "div", "p", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre":
                        let text = runs.map(\.text).joined() + current.text
                        if !text.isEmpty, !text.hasSuffix("\n") { pendingBreak = true }
                        if name == "li", !closing { emit("• ") }
                    case "b", "strong": bold = max(0, bold + delta); flush()
                    case "i", "em": italic = max(0, italic + delta); flush()
                    case "u": underline = max(0, underline + delta); flush()
                    default: break
                    }
                    i = html.index(after: close)
                    continue
                }
                if c == "&", let semi = html[i...].firstIndex(of: ";"), html.distance(from: i, to: semi) <= 8 {
                    emit(entity(String(html[html.index(after: i)..<semi])))
                    i = html.index(after: semi)
                    continue
                }
                emit(c == "\u{a0}" ? " " : String(c))
                i = html.index(after: i)
            }
            flush()
            // Leading / trailing newlines come from wrapper tags, not content.
            while let f = runs.first, f.text.hasPrefix("\n") { runs[0].text.removeFirst(); if runs[0].text.isEmpty { runs.removeFirst() } }
            while let l = runs.last, l.text.hasSuffix("\n") { runs[runs.count - 1].text.removeLast(); if runs[runs.count - 1].text.isEmpty { runs.removeLast() } }
            return runs
        }

        private static func entity(_ name: String) -> String {
            switch name {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos", "#39": return "'"
            case "nbsp": return " "
            default:
                if name.hasPrefix("#x"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { return String(Character(u)) }
                if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { return String(Character(u)) }
                return "&\(name);"
            }
        }
    }

    // MARK: - Layout

    /// A vertex placed on the page: absolute bounds and the cell.
    struct PlacedVertex {
        let cell: Cell
        let bounds: CGRect
    }

    /// Absolute bounds of every visible vertex (collapsed containers hide their children),
    /// and the origin each edge's waypoints are relative to, in draw order.
    struct Layout {
        var vertices: [PlacedVertex] = []
        var byID: [String: PlacedVertex] = [:]
        var edges: [(cell: Cell, origin: CGPoint)] = []
        var edgeOrigin: [String: CGPoint] = [:]
        /// Edge labels (relative children of an edge) by edge id.
        var edgeLabels: [String: [Cell]] = [:]
    }

    static func layout(_ page: Page) -> Layout {
        var l = Layout()
        func walk(_ c: Cell, origin: CGPoint) {
            for child in c.children where child.visible {
                if child.isVertex, child.relative, c.isEdge {
                    l.edgeLabels[c.id, default: []].append(child)
                } else if child.isVertex {
                    let r = child.geometry.offsetBy(dx: origin.x, dy: origin.y)
                    let placed = PlacedVertex(cell: child, bounds: r)
                    l.vertices.append(placed)
                    l.byID[child.id] = placed
                    if !child.collapsed { walk(child, origin: r.origin) }
                } else if child.isEdge {
                    l.edges.append((child, origin))
                    l.edgeOrigin[child.id] = origin
                    walk(child, origin: origin)
                } else {
                    walk(child, origin: origin)
                }
            }
        }
        for layer in page.layers where layer.visible { walk(layer, origin: .zero) }
        return l
    }

    /// The diagram's extent: every vertex, waypoint and terminal point.
    static func bounds(_ layout: Layout) -> CGRect {
        var r: CGRect?
        func add(_ x: CGRect) { r = r.map { $0.union(x) } ?? x }
        for v in layout.vertices { add(v.bounds.insetBy(dx: -2, dy: -2)) }
        for (e, origin) in layout.edges {
            for p in e.points + [e.sourcePoint, e.targetPoint].compactMap({ $0 }) {
                add(CGRect(x: p.x + origin.x - 1, y: p.y + origin.y - 1, width: 2, height: 2))
            }
        }
        return r ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    // MARK: - Rendering

    /// The page as a vector image (drawn on demand, so zooming stays sharp), `margin` points of
    /// background around the diagram. Default colours follow the current appearance.
    static func render(_ page: Page, margin: CGFloat = 20) -> NSImage {
        let l = layout(page)
        let b = bounds(l)
        let size = NSSize(width: ceil(b.width + 2 * margin), height: ceil(b.height + 2 * margin))
        return NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = Renderer(page: page, layout: l, context: ctx)
            r.background(rect)
            ctx.translateBy(x: margin - b.minX, y: margin - b.minY)
            r.draw()
            return true
        }
    }

    /// Draws one page into a CGContext whose coordinates are the diagram's (y down).
    final class Renderer {
        let page: Page
        let layout: Layout
        let ctx: CGContext
        /// Colours for cells without an explicit colour: the appearance's, or black / white over
        /// a page that sets its own background, so the diagram reads in both appearances.
        let foreground: NSColor
        let canvas: NSColor

        init(page: Page, layout: Layout, context: CGContext) {
            self.page = page
            self.layout = layout
            self.ctx = context
            if let bg = page.background {
                canvas = bg
                foreground = Drawio.luminance(bg) > 0.55 ? NSColor(white: 0.1, alpha: 1) : .white
            } else {
                canvas = .windowBackgroundColor
                foreground = .labelColor
            }
        }

        func background(_ rect: CGRect) {
            ctx.setFillColor(canvas.cgColor)
            ctx.fill(rect)
        }

        func draw() {
            // File order, parents before children; edges and vertices interleave as they do in draw.io.
            func walk(_ c: Cell) {
                for child in c.children where child.visible {
                    if child.isVertex, let v = layout.byID[child.id] { vertex(v) }
                    if child.isEdge, let origin = layout.edgeOrigin[child.id] { edge(child, origin: origin) }
                    if !(child.isVertex && child.collapsed) { walk(child) }
                }
            }
            for layer in page.layers where layer.visible { walk(layer) }
        }

        // MARK: Style helpers

        func fill(_ s: Style, default d: NSColor?) -> NSColor? {
            guard let v = s["fillColor"] else { return d }
            if v == "none" { return nil }
            if v == "default" { return d ?? canvas }
            return Drawio.color(v) ?? d
        }
        func stroke(_ s: Style, default d: NSColor?) -> NSColor? {
            guard let v = s["strokeColor"] else { return d }
            if v == "none" { return nil }
            if v == "default" { return d ?? foreground }
            return Drawio.color(v) ?? d
        }
        /// The label colour: `fontColor`, else black / white over an explicit fill (so coloured
        /// boxes read in dark mode too), else the theme's text colour.
        func fontColor(_ s: Style, over fill: NSColor? = nil) -> NSColor {
            if let v = s["fontColor"], v != "default", v != "none", let c = Drawio.color(v) { return c }
            if let fill, fill.alphaComponent > 0.5 { return Drawio.luminance(fill) > 0.55 ? NSColor(white: 0.1, alpha: 1) : .white }
            return foreground
        }

        /// The explicit fill colour of a cell (nil for none / default / transparent shapes).
        func explicitFill(_ s: Style) -> NSColor? {
            guard let v = s["fillColor"], v != "none", v != "default" else { return nil }
            return Drawio.color(v)
        }
        func applyOpacity(_ s: Style) {
            let o = s.number("opacity", 100)
            if o < 100 { ctx.setAlpha(max(0, o) / 100) }
        }
        func applyDash(_ s: Style, width: CGFloat) {
            guard s.flag("dashed") else { ctx.setLineDash(phase: 0, lengths: []); return }
            let pattern = (s["dashPattern"] ?? "3 3").split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) * max(1, width) }
            ctx.setLineDash(phase: 0, lengths: pattern.count >= 2 ? pattern : [3 * width, 3 * width])
        }

        // MARK: Vertices

        func vertex(_ v: PlacedVertex) {
            let c = v.cell
            let s = c.style
            let shape = s.shape ?? "rectangle"
            if shape == "group" || shape == "tableRow" { label(c, in: v.bounds); return }
            ctx.saveGState()
            applyOpacity(s)
            let rotation = s.number("rotation", 0)
            if rotation != 0 {
                ctx.translateBy(x: v.bounds.midX, y: v.bounds.midY)
                ctx.rotate(by: rotation * .pi / 180)
                ctx.translateBy(x: -v.bounds.midX, y: -v.bounds.midY)
            }
            let isText = shape == "text" || shape == "edgeLabel" || (shape == "label" && s["image"] == nil)
            let fillColor = fill(s, default: isText || shape == "image" ? nil : canvas)
            let strokeColor = stroke(s, default: isText || shape == "image" ? nil : foreground)
            let width = s.number("strokeWidth", 1)
            ctx.setLineWidth(width)
            ctx.setLineJoin(.round)
            applyDash(s, width: width)
            if let strokeColor { ctx.setStrokeColor(strokeColor.cgColor) }
            if s.flag("shadow") {
                ctx.setShadow(offset: CGSize(width: 2, height: 3), blur: 3, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            }
            let path = Shapes.path(shape, in: v.bounds, style: s)
            if let path {
                paint(path, fill: fillColor, gradient: s["gradientColor"].flatMap(Drawio.color), stroke: strokeColor, style: s, bounds: v.bounds)
            }
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            Shapes.decorate(shape, of: v, style: s, renderer: self, stroke: strokeColor, fill: fillColor)
            if shape == "image" { image(s, in: v.bounds) }
            ctx.restoreGState()
            ctx.saveGState()
            applyOpacity(s)
            if rotation != 0 {
                ctx.translateBy(x: v.bounds.midX, y: v.bounds.midY)
                ctx.rotate(by: rotation * .pi / 180)
                ctx.translateBy(x: -v.bounds.midX, y: -v.bounds.midY)
            }
            label(c, in: v.bounds)
            ctx.restoreGState()
        }

        func paint(_ path: CGPath, fill: NSColor?, gradient: NSColor?, stroke: NSColor?, style s: Style, bounds: CGRect) {
            if let fill {
                ctx.saveGState()
                ctx.addPath(path)
                if let gradient, let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [fill.cgColor, gradient.cgColor] as CFArray, locations: [0, 1]) {
                    ctx.clip()
                    let dir = s["gradientDirection"] ?? "south"
                    let (a, b): (CGPoint, CGPoint)
                    switch dir {
                    case "north": (a, b) = (CGPoint(x: bounds.midX, y: bounds.maxY), CGPoint(x: bounds.midX, y: bounds.minY))
                    case "east": (a, b) = (CGPoint(x: bounds.minX, y: bounds.midY), CGPoint(x: bounds.maxX, y: bounds.midY))
                    case "west": (a, b) = (CGPoint(x: bounds.maxX, y: bounds.midY), CGPoint(x: bounds.minX, y: bounds.midY))
                    default: (a, b) = (CGPoint(x: bounds.midX, y: bounds.minY), CGPoint(x: bounds.midX, y: bounds.maxY))
                    }
                    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                } else {
                    ctx.setFillColor(fill.cgColor)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
            if stroke != nil {
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }

        /// `shape=image;image=data:image/png,…` (base64 after the comma) or `;base64,`; URLs are left as a box.
        func image(_ s: Style, in r: CGRect) {
            guard let src = s["image"] else { return }
            var img: NSImage?
            if src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") {
                let payload = String(src[src.index(after: comma)...])
                if let d = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? payload.removingPercentEncoding?.data(using: .utf8) { img = NSImage(data: d) }
            }
            guard let img, img.size.width > 0, img.size.height > 0 else {
                ctx.setStrokeColor(foreground.withAlphaComponent(0.4).cgColor)
                ctx.setLineDash(phase: 0, lengths: [3, 3])
                ctx.stroke(r)
                return
            }
            var dst = r
            if s["imageAspect"] != "0" {
                let k = min(r.width / img.size.width, r.height / img.size.height)
                dst = CGRect(x: r.midX - img.size.width * k / 2, y: r.midY - img.size.height * k / 2, width: img.size.width * k, height: img.size.height * k)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        // MARK: Labels

        func attributed(_ c: Cell, _ s: Style, alignment: NSTextAlignment, over fill: NSColor? = nil) -> NSAttributedString {
            let size = s.number("fontSize", 12)
            let styleBits = Int(s.number("fontStyle", 0))
            let family = s["fontFamily"]
            let color = fontColor(s, over: fill)
            let para = NSMutableParagraphStyle()
            para.alignment = alignment
            para.lineBreakMode = .byWordWrapping
            func font(bold: Bool, italic: Bool) -> NSFont {
                var f = family.flatMap { NSFont(name: $0, size: size) } ?? NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if bold { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                if !traits.isEmpty, let t = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: size) { f = t }
                return f
            }
            let out = NSMutableAttributedString()
            let runs = c.html.map(Label.runs(fromHTML:)) ?? [Label.Run(text: c.label)]
            for run in runs {
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font(bold: run.bold || styleBits & 1 != 0, italic: run.italic || styleBits & 2 != 0),
                    .foregroundColor: color, .paragraphStyle: para,
                ]
                if run.underline || styleBits & 4 != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            return out
        }

        func label(_ c: Cell, in bounds: CGRect) {
            guard !c.label.isEmpty else { return }
            let s = c.style
            let shape = s.shape ?? "rectangle"
            let align: NSTextAlignment = s["align"] == "left" ? .left : s["align"] == "right" ? .right : .center
            let outside = s["verticalLabelPosition"] != nil || s["labelPosition"] != nil
            let text = attributed(c, s, alignment: align, over: outside ? nil : explicitFill(s))
            let spacing = s.number("spacing", 2)
            var box = bounds.insetBy(dx: spacing, dy: spacing)
            box.origin.x += s.number("spacingLeft", 0)
            box.size.width -= s.number("spacingLeft", 0) + s.number("spacingRight", 0)
            box.origin.y += s.number("spacingTop", 0)
            box.size.height -= s.number("spacingTop", 0) + s.number("spacingBottom", 0)
            var vAlign = s["verticalAlign"] ?? "middle"
            let vertical = !s.flag("horizontal", true)
            if shape == "swimlane" || shape == "table" {
                let start = s.number("startSize", 23)
                if vertical {
                    box = CGRect(x: bounds.minX, y: bounds.minY, width: start, height: bounds.height).insetBy(dx: spacing, dy: spacing)
                } else {
                    box = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: start).insetBy(dx: spacing, dy: spacing)
                    box.origin.x += s.number("spacingLeft", 0)
                    box.size.width -= s.number("spacingLeft", 0) + s.number("spacingRight", 0)
                }
                vAlign = "middle"
            }
            // Labels outside the shape (icons: `verticalLabelPosition=bottom;verticalAlign=top`).
            switch s["verticalLabelPosition"] {
            case "bottom": box = CGRect(x: bounds.minX - 60, y: bounds.maxY + spacing, width: bounds.width + 120, height: 200); vAlign = "top"
            case "top": box = CGRect(x: bounds.minX - 60, y: bounds.minY - 200 - spacing, width: bounds.width + 120, height: 200); vAlign = "bottom"
            default: break
            }
            switch s["labelPosition"] {
            case "right": box = CGRect(x: bounds.maxX + spacing, y: bounds.minY, width: 300, height: bounds.height)
            case "left": box = CGRect(x: bounds.minX - 300 - spacing, y: bounds.minY, width: 300, height: bounds.height)
            default: break
            }
            if vertical {
                // Rotated −90°: lay the text out in a box of swapped size around the same centre.
                ctx.saveGState()
                ctx.translateBy(x: box.midX, y: box.midY)
                ctx.rotate(by: -.pi / 2)
                let swapped = CGRect(x: -box.height / 2, y: -box.width / 2, width: box.height, height: box.width)
                drawText(text, in: swapped, wrap: s["whiteSpace"] == "wrap", vAlign: vAlign, align: align, style: s)
                ctx.restoreGState()
            } else {
                drawText(text, in: box, wrap: s["whiteSpace"] == "wrap", vAlign: vAlign, align: align, style: s)
            }
        }

        func drawText(_ text: NSAttributedString, in box: CGRect, wrap: Bool, vAlign: String, align: NSTextAlignment, style s: Style) {
            let maxWidth: CGFloat = wrap ? max(1, box.width) : 100_000
            let measured = text.boundingRect(with: CGSize(width: maxWidth, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let w = wrap ? box.width : ceil(measured.width)
            let h = ceil(measured.height)
            var x = box.minX
            if !wrap {
                switch align {
                case .left: x = box.minX
                case .right: x = box.maxX - w
                default: x = box.midX - w / 2
                }
            }
            let y: CGFloat
            switch vAlign {
            case "top": y = box.minY
            case "bottom": y = box.maxY - h
            default: y = box.midY - h / 2
            }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            if let bg = s["labelBackgroundColor"], bg != "none", let c = bg == "default" ? canvas : Drawio.color(bg) {
                ctx.setFillColor(c.cgColor)
                ctx.fill(frame.insetBy(dx: -2, dy: -1))
            }
            if let bc = s["labelBorderColor"], bc != "none", let c = bc == "default" ? foreground : Drawio.color(bc) {
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(frame.insetBy(dx: -2, dy: -1))
            }
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }

        // MARK: Edges

        func edge(_ e: Cell, origin: CGPoint) {
            let s = e.style
            guard let route = Routing.route(e, origin: origin, layout: layout) else { return }
            ctx.saveGState()
            applyOpacity(s)
            let width = s.number("strokeWidth", 1)
            let color = stroke(s, default: foreground) ?? foreground
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.butt)
            let startArrow = Arrows.Head(s["startArrow"] ?? "none")
            let endArrow = Arrows.Head(s["endArrow"] ?? "classic")
            let size = s.number("endSize", 6)
            let startSize = s.number("startSize", 6)
            // The line stops short of a filled head so the stroke does not poke through the tip.
            var pts = route
            if pts.count >= 2 {
                pts[0] = Arrows.shortened(pts[0], toward: pts[1], by: startArrow.inset(size: startSize, width: width))
                pts[pts.count - 1] = Arrows.shortened(pts[pts.count - 1], toward: pts[pts.count - 2], by: endArrow.inset(size: size, width: width))
            }
            let path = Routing.path(pts, curved: s.flag("curved"), rounded: s.flag("rounded"), radius: s.number("arcSize", 20) / 2)
            applyDash(s, width: width)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if route.count >= 2 {
                Arrows.draw(endArrow, at: route[route.count - 1], from: route[route.count - 2], size: size, width: width, filled: s.flag("endFill", endArrow.filledByDefault), ctx: ctx, color: color, canvas: canvas)
                Arrows.draw(startArrow, at: route[0], from: route[1], size: startSize, width: width, filled: s.flag("startFill", startArrow.filledByDefault), ctx: ctx, color: color, canvas: canvas)
            }
            ctx.restoreGState()
            // The edge's own label sits at the middle of the route; child labels along it.
            if !e.label.isEmpty { edgeLabel(e, at: Routing.point(along: route, fraction: 0.5), offset: .zero) }
            for child in layout.edgeLabels[e.id] ?? [] where !child.label.isEmpty {
                let fraction = (max(-1, min(1, child.geometry.minX)) + 1) / 2
                let p = Routing.point(along: route, fraction: fraction)
                let n = Routing.normal(along: route, fraction: fraction)
                let off = CGPoint(x: n.x * child.geometry.minY + child.offset.x, y: n.y * child.geometry.minY + child.offset.y)
                edgeLabel(child, at: p, offset: off)
            }
        }

        func edgeLabel(_ c: Cell, at p: CGPoint, offset: CGPoint) {
            var s = c.style
            if s["labelBackgroundColor"] == nil { s.values["labelBackgroundColor"] = "default" }
            let align: NSTextAlignment = s["align"] == "left" ? .left : s["align"] == "right" ? .right : .center
            let text = attributed(c, s, alignment: align)
            let box = CGRect(x: p.x + offset.x - 150, y: p.y + offset.y - 100, width: 300, height: 200)
            drawText(text, in: box, wrap: false, vAlign: "middle", align: .center, style: s)
        }
    }

    // MARK: - Shapes

    enum Shapes {
        /// The outline of `shape` in `r`; nil for shapes that draw nothing themselves.
        static func path(_ shape: String, in r: CGRect, style s: Style) -> CGPath? {
            let w = r.width, h = r.height, x = r.minX, y = r.minY
            let p = CGMutablePath()
            func pts(_ list: [(CGFloat, CGFloat)]) -> CGPath {
                p.addLines(between: list.map { CGPoint(x: x + $0.0, y: y + $0.1) })
                p.closeSubpath()
                return p
            }
            switch shape {
            case "ellipse":
                return CGPath(ellipseIn: r, transform: nil)
            case "rhombus":
                return pts([(w / 2, 0), (w, h / 2), (w / 2, h), (0, h / 2)])
            case "triangle":
                switch s["direction"] ?? "east" {
                case "north": return pts([(w / 2, 0), (w, h), (0, h)])
                case "south": return pts([(0, 0), (w, 0), (w / 2, h)])
                case "west": return pts([(w, 0), (w, h), (0, h / 2)])
                default: return pts([(0, 0), (w, h / 2), (0, h)])
                }
            case "hexagon":
                let d = s.flag("fixedSize") ? min(s.number("size", 20), w / 2) : w * s.number("size", 0.25)
                return pts([(d, 0), (w - d, 0), (w, h / 2), (w - d, h), (d, h), (0, h / 2)])
            case "parallelogram":
                let d = s.flag("fixedSize") ? min(s.number("size", 20), w) : w * s.number("size", 0.2)
                return pts([(0, h), (d, 0), (w, 0), (w - d, h)])
            case "step":
                let d = s.flag("fixedSize") ? min(s.number("size", 20), w) : w * s.number("size", 0.2)
                return pts([(0, 0), (w - d, 0), (w, h / 2), (w - d, h), (0, h), (d, h / 2)])
            case "card":
                let d = min(s.number("size", 30), w, h)
                return pts([(d, 0), (w, 0), (w, h), (0, h), (0, d)])
            case "note":
                let d = min(s.number("size", 30), w, h)
                return pts([(0, 0), (w - d, 0), (w, d), (w, h), (0, h)])
            case "cylinder", "cylinder3", "cylinder2":
                let dy = min(s.number("size", 15), h / 2)
                p.move(to: CGPoint(x: x, y: y + dy))
                p.addCurve(to: CGPoint(x: x + w, y: y + dy), control1: CGPoint(x: x, y: y - dy / 3), control2: CGPoint(x: x + w, y: y - dy / 3))
                p.addLine(to: CGPoint(x: x + w, y: y + h - dy))
                p.addCurve(to: CGPoint(x: x, y: y + h - dy), control1: CGPoint(x: x + w, y: y + h + dy / 3), control2: CGPoint(x: x, y: y + h + dy / 3))
                p.closeSubpath()
                return p
            case "document":
                let dy = h * max(0, min(1, s.number("size", 0.3)))
                let fy: CGFloat = 1.4
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + w, y: y))
                p.addLine(to: CGPoint(x: x + w, y: y + h - dy / 2))
                p.addQuadCurve(to: CGPoint(x: x + w / 2, y: y + h - dy / 2), control: CGPoint(x: x + w * 3 / 4, y: y + h - dy * fy))
                p.addQuadCurve(to: CGPoint(x: x, y: y + h - dy / 2), control: CGPoint(x: x + w / 4, y: y + h - dy * (1 - fy)))
                p.closeSubpath()
                return p
            case "cloud":
                p.move(to: CGPoint(x: x + 0.25 * w, y: y + 0.25 * h))
                p.addCurve(to: CGPoint(x: x + 0.16 * w, y: y + 0.55 * h), control1: CGPoint(x: x + 0.05 * w, y: y + 0.25 * h), control2: CGPoint(x: x, y: y + 0.5 * h))
                p.addCurve(to: CGPoint(x: x + 0.31 * w, y: y + 0.8 * h), control1: CGPoint(x: x, y: y + 0.66 * h), control2: CGPoint(x: x + 0.18 * w, y: y + 0.9 * h))
                p.addCurve(to: CGPoint(x: x + 0.8 * w, y: y + 0.8 * h), control1: CGPoint(x: x + 0.4 * w, y: y + h), control2: CGPoint(x: x + 0.7 * w, y: y + h))
                p.addCurve(to: CGPoint(x: x + 0.875 * w, y: y + 0.5 * h), control1: CGPoint(x: x + w, y: y + 0.8 * h), control2: CGPoint(x: x + w, y: y + 0.6 * h))
                p.addCurve(to: CGPoint(x: x + 0.625 * w, y: y + 0.2 * h), control1: CGPoint(x: x + w, y: y + 0.3 * h), control2: CGPoint(x: x + 0.8 * w, y: y + 0.1 * h))
                p.addCurve(to: CGPoint(x: x + 0.25 * w, y: y + 0.25 * h), control1: CGPoint(x: x + 0.5 * w, y: y + 0.05 * h), control2: CGPoint(x: x + 0.3 * w, y: y + 0.05 * h))
                p.closeSubpath()
                return p
            case "line":
                p.move(to: CGPoint(x: x, y: y + h / 2))
                p.addLine(to: CGPoint(x: x + w, y: y + h / 2))
                return p
            case "partialRectangle":
                // Only the sides that are on (`top=0` turns the top off); the fill is the whole box.
                var any = false
                for (key, a, b) in [("top", CGPoint(x: x, y: y), CGPoint(x: x + w, y: y)), ("right", CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h)),
                                    ("bottom", CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)), ("left", CGPoint(x: x, y: y + h), CGPoint(x: x, y: y))]
                    where s.flag(key, true) {
                    p.move(to: a)
                    p.addLine(to: b)
                    any = true
                }
                return any ? p : nil
            case "text", "edgeLabel", "image":
                return s["fillColor"] != nil || s["strokeColor"] != nil ? CGPath(rect: r, transform: nil) : nil
            default:
                if s.flag("rounded") {
                    let f = s.number("arcSize", 15) / 100
                    let radius = s.flag("absoluteArcSize") ? s.number("arcSize", 20) / 2 : min(w * f, h * f)
                    return CGPath(roundedRect: r, cornerWidth: min(radius, w / 2), cornerHeight: min(radius, h / 2), transform: nil)
                }
                return CGPath(rect: r, transform: nil)
            }
        }

        /// Inner lines after the outline: swimlane / table title bands, the cylinder's rim, the
        /// process bars, the note's fold, table grid lines.
        static func decorate(_ shape: String, of v: PlacedVertex, style s: Style, renderer: Renderer, stroke: NSColor?, fill: NSColor?) {
            let ctx = renderer.ctx
            let r = v.bounds
            let w = r.width, h = r.height, x = r.minX, y = r.minY
            ctx.setLineDash(phase: 0, lengths: [])
            switch shape {
            case "swimlane", "table":
                let start = min(s.number("startSize", 23), s.flag("horizontal", true) ? h : w)
                // The outline was filled with fillColor; the body gets swimlaneFillColor (default: the canvas) over it.
                var body: NSColor? = fill == nil ? nil : renderer.canvas
                if let v = s["swimlaneFillColor"] { body = v == "none" ? nil : v == "default" ? renderer.canvas : Drawio.color(v) }
                if let body {
                    ctx.setFillColor(body.cgColor)
                    ctx.fill(s.flag("horizontal", true) ? CGRect(x: x, y: y + start, width: w, height: h - start) : CGRect(x: x + start, y: y, width: w - start, height: h))
                }
                if let stroke {
                    ctx.setStrokeColor(stroke.cgColor)
                    ctx.stroke(r)
                    ctx.strokeLineSegments(between: s.flag("horizontal", true)
                        ? [CGPoint(x: x, y: y + start), CGPoint(x: x + w, y: y + start)]
                        : [CGPoint(x: x + start, y: y), CGPoint(x: x + start, y: y + h)])
                }
            case "cylinder", "cylinder3", "cylinder2":
                guard let stroke else { break }
                let dy = min(s.number("size", 15), h / 2)
                ctx.setStrokeColor(stroke.cgColor)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: y + dy))
                p.addCurve(to: CGPoint(x: x + w, y: y + dy), control1: CGPoint(x: x, y: y + dy * 7 / 3), control2: CGPoint(x: x + w, y: y + dy * 7 / 3))
                ctx.addPath(p)
                ctx.strokePath()
            case "process":
                guard let stroke else { break }
                let d = s.flag("fixedSize") ? min(s.number("size", 20), w / 2) : w * s.number("size", 0.1)
                ctx.setStrokeColor(stroke.cgColor)
                ctx.strokeLineSegments(between: [CGPoint(x: x + d, y: y), CGPoint(x: x + d, y: y + h), CGPoint(x: x + w - d, y: y), CGPoint(x: x + w - d, y: y + h)])
            case "note":
                guard let stroke else { break }
                let d = min(s.number("size", 30), w, h)
                ctx.setStrokeColor(stroke.cgColor)
                let p = CGMutablePath()
                p.addLines(between: [CGPoint(x: x + w - d, y: y), CGPoint(x: x + w - d, y: y + d), CGPoint(x: x + w, y: y + d)])
                ctx.setFillColor(NSColor.black.withAlphaComponent(s.number("darkOpacity", 0.05)).cgColor)
                ctx.addPath(p)
                ctx.closePath()
                ctx.fillPath()
                ctx.addPath(p)
                ctx.strokePath()
            default:
                break
            }
            // Table grid: a line under each row (rowLines) and between the cells of each row (columnLines).
            if shape == "table", let stroke {
                ctx.setStrokeColor(stroke.cgColor)
                var segments: [CGPoint] = []
                for (i, row) in v.cell.children.enumerated() where row.isVertex {
                    let ry = r.minY + row.geometry.minY
                    if s.flag("rowLines", true), i > 0 { segments += [CGPoint(x: x, y: ry), CGPoint(x: x + w, y: ry)] }
                    if s.flag("columnLines", true) {
                        for col in row.children.dropFirst() where col.isVertex {
                            let cx = x + col.geometry.minX
                            segments += [CGPoint(x: cx, y: ry), CGPoint(x: cx, y: ry + row.geometry.height)]
                        }
                    }
                }
                ctx.strokeLineSegments(between: segments)
            }
        }

        /// Where a line from the centre towards `toward` leaves the shape (the perimeter).
        static func perimeter(_ shape: String, of r: CGRect, toward p: CGPoint) -> CGPoint {
            let c = CGPoint(x: r.midX, y: r.midY)
            let dx = p.x - c.x, dy = p.y - c.y
            if dx == 0, dy == 0 { return c }
            switch shape {
            case "ellipse", "cloud":
                let a = r.width / 2, b = r.height / 2
                let t = 1 / sqrt((dx * dx) / (a * a) + (dy * dy) / (b * b))
                return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
            case "rhombus":
                let a = r.width / 2, b = r.height / 2
                let t = 1 / (abs(dx) / a + abs(dy) / b)
                return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
            default:
                let a = r.width / 2, b = r.height / 2
                let t = min(a / max(abs(dx), 0.0001), b / max(abs(dy), 0.0001))
                return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
            }
        }
    }

    // MARK: - Edge routing

    enum Routing {
        /// The points of an edge, in page coordinates: terminal points on the shapes (or the
        /// fixed exit / entry points, or the dangling source / target points), with the waypoints
        /// between; orthogonal styles get axis-aligned segments.
        static func route(_ e: Cell, origin: CGPoint, layout: Layout) -> [CGPoint]? {
            let s = e.style
            let orthogonal = ["orthogonalEdgeStyle", "elbowEdgeStyle", "entityRelationEdgeStyle", "segmentEdgeStyle"].contains(s["edgeStyle"] ?? "")
            let way = e.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            let src = e.source.flatMap { layout.byID[$0] }
            let dst = e.target.flatMap { layout.byID[$0] }
            let srcFixed = fixedPoint(src, s, "exit")
            let dstFixed = fixedPoint(dst, s, "entry")
            let srcLoose = e.sourcePoint.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            let dstLoose = e.targetPoint.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            guard src != nil || srcLoose != nil, dst != nil || dstLoose != nil else { return nil }

            if orthogonal, let src, let dst, way.isEmpty {
                return orthogonalRoute(from: src, to: dst, exit: srcFixed, entry: dstFixed)
            }
            // Reference points the terminals aim at.
            let srcRef = way.first ?? dstFixed ?? dst.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? dstLoose!
            let dstRef = way.last ?? srcFixed ?? src.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? srcLoose!
            let p0 = srcFixed ?? src.map { terminal($0, toward: srcRef, orthogonal: orthogonal) } ?? srcLoose!
            let p1 = dstFixed ?? dst.map { terminal($0, toward: dstRef, orthogonal: orthogonal) } ?? dstLoose!
            var pts = [p0] + way + [p1]
            if orthogonal { pts = squared(pts) }
            return pts
        }

        /// `exitX=0.5;exitY=1` (plus `exitDx` / `exitDy`) on the source, `entryX` … on the target.
        static func fixedPoint(_ v: PlacedVertex?, _ s: Style, _ key: String) -> CGPoint? {
            guard let v, let xs = s[key + "X"], let ys = s[key + "Y"], let fx = Double(xs), let fy = Double(ys) else { return nil }
            return CGPoint(x: v.bounds.minX + v.bounds.width * fx + s.number(key + "Dx", 0), y: v.bounds.minY + v.bounds.height * fy + s.number(key + "Dy", 0))
        }

        /// Where an edge aimed at `p` meets the shape: orthogonal edges leave through the side
        /// facing `p`, straight edges through the perimeter on the line to `p`.
        static func terminal(_ v: PlacedVertex, toward p: CGPoint, orthogonal: Bool) -> CGPoint {
            let r = v.bounds
            if orthogonal {
                if p.x >= r.minX, p.x <= r.maxX { return CGPoint(x: p.x, y: p.y < r.midY ? r.minY : r.maxY) }
                if p.y >= r.minY, p.y <= r.maxY { return CGPoint(x: p.x < r.midX ? r.minX : r.maxX, y: p.y) }
                // Diagonal: leave through the side the point is further from, at the centre of that side.
                let dx = p.x < r.minX ? r.minX - p.x : p.x - r.maxX
                let dy = p.y < r.minY ? r.minY - p.y : p.y - r.maxY
                return dx >= dy ? CGPoint(x: p.x < r.midX ? r.minX : r.maxX, y: r.midY) : CGPoint(x: r.midX, y: p.y < r.midY ? r.minY : r.maxY)
            }
            return Shapes.perimeter(v.cell.style.shape ?? "rectangle", of: r, toward: p)
        }

        /// Side of `r` a point `p` on its boundary belongs to, as an outward unit vector.
        static func normal(of r: CGRect, at p: CGPoint) -> CGPoint {
            let d = [(abs(p.y - r.minY), CGPoint(x: 0, y: -1)), (abs(p.y - r.maxY), CGPoint(x: 0, y: 1)),
                     (abs(p.x - r.minX), CGPoint(x: -1, y: 0)), (abs(p.x - r.maxX), CGPoint(x: 1, y: 0))]
            return d.min { $0.0 < $1.0 }!.1
        }

        /// Two shapes, no waypoints: leave through the facing sides, one or two elbows between.
        static func orthogonalRoute(from s: PlacedVertex, to t: PlacedVertex, exit: CGPoint?, entry: CGPoint?) -> [CGPoint] {
            let a = s.bounds, b = t.bounds
            var p0: CGPoint, n0: CGPoint, p1: CGPoint, n1: CGPoint
            let gapX = b.minX > a.maxX || b.maxX < a.minX
            let gapY = b.minY > a.maxY || b.maxY < a.minY
            let horizontal: Bool
            if let exit { horizontal = normal(of: a, at: exit).x != 0 } else if let entry { horizontal = normal(of: b, at: entry).x != 0 } else if gapX == gapY { horizontal = abs(b.midX - a.midX) > abs(b.midY - a.midY) } else { horizontal = gapX }
            if let exit {
                p0 = exit; n0 = normal(of: a, at: exit)
            } else if horizontal {
                let right = b.midX >= a.midX
                p0 = CGPoint(x: right ? a.maxX : a.minX, y: a.midY); n0 = CGPoint(x: right ? 1 : -1, y: 0)
            } else {
                let down = b.midY >= a.midY
                p0 = CGPoint(x: a.midX, y: down ? a.maxY : a.minY); n0 = CGPoint(x: 0, y: down ? 1 : -1)
            }
            if let entry {
                p1 = entry; n1 = normal(of: b, at: entry)
            } else if horizontal {
                let fromLeft = p0.x <= b.midX
                p1 = CGPoint(x: fromLeft ? b.minX : b.maxX, y: b.midY); n1 = CGPoint(x: fromLeft ? -1 : 1, y: 0)
            } else {
                let fromAbove = p0.y <= b.midY
                p1 = CGPoint(x: b.midX, y: fromAbove ? b.minY : b.maxY); n1 = CGPoint(x: 0, y: fromAbove ? -1 : 1)
            }
            // Overlapping shapes with no fixed points: the centres, trimmed to the perimeters.
            if exit == nil, entry == nil, !gapX, !gapY {
                return [Shapes.perimeter(s.cell.style.shape ?? "rectangle", of: a, toward: CGPoint(x: b.midX, y: b.midY)),
                        Shapes.perimeter(t.cell.style.shape ?? "rectangle", of: b, toward: CGPoint(x: a.midX, y: a.midY))]
            }
            if n0.x != 0, n1.x != 0 {
                if p0.y == p1.y { return [p0, p1] }
                let mx = (p0.x + p1.x) / 2
                return [p0, CGPoint(x: mx, y: p0.y), CGPoint(x: mx, y: p1.y), p1]
            }
            if n0.y != 0, n1.y != 0 {
                if p0.x == p1.x { return [p0, p1] }
                let my = (p0.y + p1.y) / 2
                return [p0, CGPoint(x: p0.x, y: my), CGPoint(x: p1.x, y: my), p1]
            }
            if n0.x != 0 { return [p0, CGPoint(x: p1.x, y: p0.y), p1] }
            return [p0, CGPoint(x: p0.x, y: p1.y), p1]
        }

        /// Make consecutive points axis-aligned by inserting a corner, continuing the direction of
        /// the previous segment.
        static func squared(_ pts: [CGPoint]) -> [CGPoint] {
            guard pts.count >= 2 else { return pts }
            var out = [pts[0]]
            var lastVertical: Bool? = nil
            for p in pts.dropFirst() {
                let a = out[out.count - 1]
                if abs(a.x - p.x) > 0.5, abs(a.y - p.y) > 0.5 {
                    let corner = (lastVertical ?? (abs(p.x - a.x) < abs(p.y - a.y))) ? CGPoint(x: a.x, y: p.y) : CGPoint(x: p.x, y: a.y)
                    out.append(corner)
                    lastVertical = abs(corner.x - p.x) < 0.5
                } else {
                    lastVertical = abs(a.x - p.x) < 0.5
                }
                out.append(p)
            }
            return out
        }

        /// A polyline; `curved` makes it a smooth curve through the waypoints (control points);
        /// `rounded` rounds the corners by `radius`.
        static func path(_ pts: [CGPoint], curved: Bool, rounded: Bool, radius: CGFloat) -> CGPath {
            let p = CGMutablePath()
            guard let first = pts.first else { return p }
            p.move(to: first)
            if curved, pts.count >= 3 {
                for i in 1..<(pts.count - 1) {
                    let c = pts[i]
                    let end = i == pts.count - 2 ? pts[i + 1] : CGPoint(x: (c.x + pts[i + 1].x) / 2, y: (c.y + pts[i + 1].y) / 2)
                    p.addQuadCurve(to: end, control: c)
                }
                return p
            }
            if rounded, pts.count >= 3 {
                for i in 1..<(pts.count - 1) {
                    let prev = pts[i - 1], c = pts[i], next = pts[i + 1]
                    let d1 = hypot(c.x - prev.x, c.y - prev.y), d2 = hypot(next.x - c.x, next.y - c.y)
                    let r = min(radius, d1 / 2, d2 / 2)
                    guard r > 0.5 else { p.addLine(to: c); continue }
                    let a = CGPoint(x: c.x + (prev.x - c.x) / d1 * r, y: c.y + (prev.y - c.y) / d1 * r)
                    let b = CGPoint(x: c.x + (next.x - c.x) / d2 * r, y: c.y + (next.y - c.y) / d2 * r)
                    p.addLine(to: a)
                    p.addQuadCurve(to: b, control: c)
                }
                p.addLine(to: pts[pts.count - 1])
                return p
            }
            for q in pts.dropFirst() { p.addLine(to: q) }
            return p
        }

        static func length(_ pts: [CGPoint]) -> CGFloat {
            zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }

        /// The point `fraction` (0…1) of the way along the polyline.
        static func point(along pts: [CGPoint], fraction: CGFloat) -> CGPoint {
            guard pts.count >= 2 else { return pts.first ?? .zero }
            var remaining = length(pts) * max(0, min(1, fraction))
            for (a, b) in zip(pts, pts.dropFirst()) {
                let d = hypot(b.x - a.x, b.y - a.y)
                if remaining <= d || d == 0 {
                    let t = d == 0 ? 0 : remaining / d
                    return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                remaining -= d
            }
            return pts[pts.count - 1]
        }

        /// Unit normal (to the left of the direction of travel) of the segment at `fraction`.
        static func normal(along pts: [CGPoint], fraction: CGFloat) -> CGPoint {
            guard pts.count >= 2 else { return CGPoint(x: 0, y: -1) }
            var remaining = length(pts) * max(0, min(1, fraction))
            var seg = (pts[0], pts[1])
            for (a, b) in zip(pts, pts.dropFirst()) {
                seg = (a, b)
                let d = hypot(b.x - a.x, b.y - a.y)
                if remaining <= d { break }
                remaining -= d
            }
            let d = hypot(seg.1.x - seg.0.x, seg.1.y - seg.0.y)
            guard d > 0 else { return CGPoint(x: 0, y: -1) }
            return CGPoint(x: (seg.1.y - seg.0.y) / d, y: -(seg.1.x - seg.0.x) / d)
        }
    }

    // MARK: - Arrow heads

    enum Arrows {
        enum Head {
            case none, classic, block, open, oval, diamond, diamondThin, erMany, erOne, erMandOne, erZeroToMany, erZeroToOne, bar

            init(_ name: String) {
                switch name {
                case "none": self = .none
                case "classic", "classicThin": self = .classic
                case "block", "blockThin": self = .block
                case "open", "openThin", "openAsync", "async": self = .open
                case "oval", "circle", "circlePlus": self = .oval
                case "diamond": self = .diamond
                case "diamondThin": self = .diamondThin
                case "ERmany", "ERoneToMany": self = .erMany
                case "ERone": self = .erOne
                case "ERmandOne": self = .erMandOne
                case "ERzeroToMany": self = .erZeroToMany
                case "ERzeroToOne": self = .erZeroToOne
                case "cross", "dash", "halfCircle", "box", "baseDash": self = .bar
                default: self = .classic
                }
            }

            var filledByDefault: Bool { self != .open }

            /// How far the line stops before the tip (filled heads cover the gap).
            func inset(size: CGFloat, width: CGFloat) -> CGFloat {
                switch self {
                case .classic, .block: return size + width
                case .oval: return size + width
                case .diamond, .diamondThin: return (size + width) * 2
                default: return 0
                }
            }
        }

        static func shortened(_ p: CGPoint, toward q: CGPoint, by d: CGFloat) -> CGPoint {
            let len = hypot(q.x - p.x, q.y - p.y)
            guard d > 0, len > d else { return p }
            return CGPoint(x: p.x + (q.x - p.x) / len * d, y: p.y + (q.y - p.y) / len * d)
        }

        /// Draw `head` with its tip at `tip`, pointing away from `from`.
        static func draw(_ head: Head, at tip: CGPoint, from: CGPoint, size: CGFloat, width: CGFloat, filled: Bool, ctx: CGContext, color: NSColor, canvas: NSColor) {
            guard head != .none else { return }
            let len = hypot(tip.x - from.x, tip.y - from.y)
            guard len > 0 else { return }
            let u = CGPoint(x: (tip.x - from.x) / len, y: (tip.y - from.y) / len) // along the line, towards the tip
            let n = CGPoint(x: -u.y, y: u.x)
            let s = size + width
            func at(_ back: CGFloat, _ side: CGFloat) -> CGPoint { CGPoint(x: tip.x - u.x * back + n.x * side, y: tip.y - u.y * back + n.y * side) }
            let p = CGMutablePath()
            ctx.setLineWidth(width)
            ctx.setFillColor((filled ? color : canvas).cgColor)
            ctx.setStrokeColor(color.cgColor)
            switch head {
            case .classic:
                p.addLines(between: [tip, at(s, s / 2), at(s * 0.75, 0), at(s, -s / 2)])
                p.closeSubpath()
                ctx.addPath(p); ctx.drawPath(using: .fillStroke)
            case .block:
                p.addLines(between: [tip, at(s, s / 2), at(s, -s / 2)])
                p.closeSubpath()
                ctx.addPath(p); ctx.drawPath(using: .fillStroke)
            case .open:
                p.addLines(between: [at(s, s / 2), tip, at(s, -s / 2)])
                ctx.addPath(p); ctx.strokePath()
            case .oval:
                let c = at(s / 2, 0)
                ctx.addEllipse(in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                ctx.drawPath(using: .fillStroke)
            case .diamond, .diamondThin:
                let half = head == .diamond ? s * 0.6 : s * 0.4
                p.addLines(between: [tip, at(s, half), at(s * 2, 0), at(s, -half)])
                p.closeSubpath()
                ctx.addPath(p); ctx.drawPath(using: .fillStroke)
            case .erMany, .erZeroToMany:
                let foot = s * 1.5
                p.move(to: at(foot, 0)); p.addLine(to: at(0, foot / 2))
                p.move(to: at(foot, 0)); p.addLine(to: tip)
                p.move(to: at(foot, 0)); p.addLine(to: at(0, -foot / 2))
                ctx.addPath(p); ctx.strokePath()
                if head == .erZeroToMany {
                    let c = at(foot + s / 2 + 1, 0)
                    ctx.setFillColor(canvas.cgColor)
                    ctx.addEllipse(in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                    ctx.drawPath(using: .fillStroke)
                }
            case .erOne, .erMandOne, .erZeroToOne, .bar:
                let d = s
                p.move(to: at(d, s / 2)); p.addLine(to: at(d, -s / 2))
                if head == .erMandOne { p.move(to: at(d * 1.8, s / 2)); p.addLine(to: at(d * 1.8, -s / 2)) }
                ctx.addPath(p); ctx.strokePath()
                if head == .erZeroToOne {
                    let c = at(d * 2 + s / 2, 0)
                    ctx.setFillColor(canvas.cgColor)
                    ctx.addEllipse(in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                    ctx.drawPath(using: .fillStroke)
                }
            case .none:
                break
            }
        }
    }
}
