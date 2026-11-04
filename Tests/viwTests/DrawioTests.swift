import AppKit
import Testing
@testable import viw

@Suite struct DrawioTests {
    @Test func parsesPagesAndCells() throws {
        let pages = try Drawio.parse(url: try fixture("sample.drawio"))
        #expect(pages.map(\.name) == ["Flow", "Architecture", "ER"])
        #expect(pages[0].cells.count == 21)
        #expect(pages[1].background != nil)   // background="#fafafa"
        #expect(pages[0].background == nil)
        let known = try #require(pages[0].cells["known"])
        #expect(known.isVertex && !known.isEdge)
        #expect(known.style.shape == "rhombus")
        #expect(known.label == "Known\nextension?")           // html=1: <br> → newline
        #expect(known.geometry == CGRect(x: 150, y: 290, width: 140, height: 90))
        let e5 = try #require(pages[0].cells["e5"])
        #expect(e5.isEdge && e5.source == "plain" && e5.target == "end")
        #expect(e5.points == [CGPoint(x: 440, y: 570)])
        let dangling = try #require(pages[1].cells["a8"])
        #expect(dangling.sourcePoint == CGPoint(x: 440, y: 520) && dangling.targetPoint == CGPoint(x: 580, y: 520))
        // <object label=… id=…><mxCell/></object>: the wrapper's id and label.
        let uo = try #require(pages[2].cells["uo"])
        #expect(uo.label == "A UserObject cell with & entities\nand a div line")
        #expect(Drawio.Label.runs(fromHTML: "A &lt;u&gt;x&lt;/u&gt;".replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">"))
                == [.init(text: "A "), .init(text: "x", underline: true)])
        #expect(pages[2].cells["hidden"]?.visible == false)
        #expect(pages[2].cells["collapsed"]?.collapsed == true)
    }

    @Test func compressedPagesMatchPlainOnes() throws {
        let plain = try Drawio.parse(url: try fixture("sample.drawio"))
        let packed = try Drawio.parse(url: try fixture("compressed.drawio"))
        #expect(packed.map(\.name) == plain.map(\.name))
        for (a, b) in zip(plain, packed) {
            #expect(Set(a.cells.keys) == Set(b.cells.keys))
            for (id, cell) in a.cells {
                #expect(b.cells[id]?.label == cell.label, "label of \(id)")
                #expect(b.cells[id]?.geometry == cell.geometry, "geometry of \(id)")
                #expect(b.cells[id]?.style.values == cell.style.values, "style of \(id)")
            }
        }
        #expect(Drawio.decode("not base64 at all!") == nil)
    }

    @Test func labelsFromHTML() {
        #expect(Drawio.Label.text(fromHTML: "<b>viw sample</b> — a flowchart<br><i>drawn by viw itself</i>") == "viw sample — a flowchart\ndrawn by viw itself")
        #expect(Drawio.Label.runs(fromHTML: "<b>viw sample</b> — a flowchart<br><i>drawn by viw itself</i>") == [
            .init(text: "viw sample", bold: true), .init(text: " — a flowchart\n"), .init(text: "drawn by viw itself", italic: true),
        ])
        #expect(Drawio.Label.text(fromHTML: "<div>one</div><div>two</div>") == "one\ntwo")
        #expect(Drawio.Label.text(fromHTML: "a&amp;b &lt;c&gt; &nbsp;d &#x41;&#66;") == "a&b <c>  d AB")
        #expect(Drawio.Label.text(fromHTML: "<ul><li>x</li><li>y</li></ul>") == "• x\n• y")
        #expect(Drawio.Label.text(fromHTML: "<font style=\"font-size: 20px\">big</font>") == "big")
        #expect(Drawio.Label.text(fromHTML: "plain") == "plain")
    }

    @Test func styles() {
        let s = Drawio.Style("rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=none;")
        #expect(s.shape == nil && s.flag("rounded") && s["fillColor"] == "#dae8fc" && s.number("strokeWidth", 1) == 1)
        #expect(Drawio.Style("ellipse;shape=cloud;whiteSpace=wrap;").shape == "cloud")
        #expect(Drawio.Style("swimlane;startSize=30;").shape == "swimlane")
        #expect(Drawio.Style("text;html=1;").flag("horizontal", true))
        #expect(Drawio.Style("horizontal=0;").flag("horizontal", true) == false)
        #expect(Drawio.color("#ff0000") == NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(Drawio.color("#fff")?.usingColorSpace(.sRGB)?.redComponent == 1)
        #expect(Drawio.color("none") == nil)
    }

    @Test func layoutResolvesParentsAndHidesCollapsed() throws {
        let pages = try Drawio.parse(url: try fixture("sample.drawio"))
        let arch = Drawio.layout(pages[1])
        // worker2 sits in a group inside the swimlane: 40 + 220 + 0, 40 + 60 + 100.
        #expect(arch.byID["worker2"]?.bounds == CGRect(x: 260, y: 200, width: 100, height: 50))
        #expect(arch.byID["queue"]?.bounds == CGRect(x: 420, y: 150, width: 100, height: 50))
        // Edges inside the group route in the group's coordinates.
        #expect(arch.edgeOrigin["a3"] == CGPoint(x: 260, y: 100))
        let er = Drawio.layout(pages[2])
        #expect(er.byID["hidden"] == nil)                  // visible="0"
        #expect(er.byID["collapsed"]?.bounds.height == 30) // collapsed: the small geometry
        #expect(er.byID["inside"] == nil)                  // its children are not laid out
        #expect(er.byID["t1r2c2"]?.bounds == CGRect(x: 80, y: 100, width: 160, height: 30))
        let flowBounds = Drawio.bounds(Drawio.layout(pages[0]))
        #expect(flowBounds.minX == 18 && flowBounds.minY == 18) // the document shape at (20, 430) and the title at y = 20, minus 2
    }

    @Test func routesEdges() throws {
        let pages = try Drawio.parse(url: try fixture("sample.drawio"))
        let flow = Drawio.layout(pages[0])
        func route(_ id: String) -> [CGPoint]? { Drawio.Routing.route(pages[0].cells[id]!, origin: flow.edgeOrigin[id]!, layout: flow) }
        // Vertical neighbours: a straight orthogonal line from the bottom of one to the top of the next.
        #expect(route("e3") == [CGPoint(x: 220, y: 380), CGPoint(x: 220, y: 430)])
        // Side by side: out of the right side, into the left side, same height.
        #expect(route("e4") == [CGPoint(x: 290, y: 335), CGPoint(x: 380, y: 335)])
        // One waypoint: down to it, then left into the end ellipse at the waypoint's height.
        #expect(route("e5") == [CGPoint(x: 440, y: 365), CGPoint(x: 440, y: 570), CGPoint(x: 280, y: 570)])
        // Offset boxes: two elbows at the middle.
        let e1 = try #require(route("e1"))
        #expect(e1.first == CGPoint(x: 220, y: 150) && e1.last == CGPoint(x: 220, y: 190))
        let arch = Drawio.layout(pages[1])
        // Dangling edge: the source / target points as they are.
        #expect(Drawio.Routing.route(pages[1].cells["a8"]!, origin: .zero, layout: arch) == [CGPoint(x: 440, y: 520), CGPoint(x: 580, y: 520)])
        // entryX=0.5;entryY=1 on the swimlane: the route ends at the bottom centre.
        #expect(Drawio.Routing.route(pages[1].cells["a6"]!, origin: .zero, layout: arch)?.last == CGPoint(x: 300, y: 340))
        // Straight edges leave through the perimeter towards the other end: the ellipse's edge, not its box.
        let e8 = try #require(route("e8"))
        #expect(e8.count == 2 && abs(e8[0].x - 120) < 0.01) // right edge of the document shape
        #expect(Drawio.Routing.squared([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]) == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        #expect(Drawio.Routing.point(along: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)], fraction: 0.5) == CGPoint(x: 10, y: 0))
    }

    @Test func rendersAnImageOfTheDiagramSize() throws {
        let pages = try Drawio.parse(url: try fixture("sample.drawio"))
        let b = Drawio.bounds(Drawio.layout(pages[0]))
        let image = Drawio.render(pages[0])
        #expect(image.size == NSSize(width: ceil(b.width + 40), height: ceil(b.height + 40)))
        #expect(image.tiffRepresentation != nil) // the drawing handler runs without throwing
    }

    @Test func rejectsOtherFiles() throws {
        #expect(throws: (any Error).self) { try Drawio.parse(url: try fixture("sample.ipynb")) }
        #expect(throws: (any Error).self) { try Drawio.parse(data: Data("<svg/>".utf8)) }
        #expect(throws: (any Error).self) { try Drawio.parse(data: Data("<mxfile><diagram name=\"x\">@@@</diagram></mxfile>".utf8)) }
        // A bare model (no <mxfile>) is one unnamed page.
        let bare = try Drawio.parse(data: Data("<mxGraphModel><root><mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/></root></mxGraphModel>".utf8))
        #expect(bare.count == 1 && bare[0].cells.count == 2)
    }
}
