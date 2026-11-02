import Foundation

/// A small DOM over Foundation's XMLParser, for the OOXML parts that are read as a whole
/// (a Word body, a slide). Element names keep their prefix (`w:p`); `XMLScanner` remains
/// the choice for the big, flat parts (sheet data, shared strings).
final class XMLTree {
    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLTree] = []
    private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) -> XMLTree? {
        final class D: NSObject, XMLParserDelegate {
            var stack: [XMLTree] = [XMLTree(name: "", attributes: [:])]
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                let node = XMLTree(name: e, attributes: a)
                stack[stack.count - 1].children.append(node)
                stack.append(node)
            }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
            func parser(_ p: XMLParser, foundCharacters s: String) { stack[stack.count - 1].text += s }
        }
        let d = D()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse(), let root = d.stack.first?.children.first else { return nil }
        return root
    }

    subscript(_ name: String) -> XMLTree? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }
    /// First element with `name` anywhere below this one (depth first).
    func find(_ name: String) -> XMLTree? {
        for c in children { if c.name == name { return c }; if let f = c.find(name) { return f } }
        return nil
    }
    /// Every element with `name` below this one, document order.
    func findAll(_ name: String) -> [XMLTree] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.findAll(name) }
    }
}
