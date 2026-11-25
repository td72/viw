import Foundation

/// A parsed JSON value as a tree that keeps what the file says: key order, duplicate keys and
/// the spelling of numbers. Nodes are objects so NSOutlineView can hold them as items.
final class JSONNode {
    enum Value: Equatable {
        case object, array
        case string(String)
        case number(String)  // as written
        case bool(Bool)
        case null
        case invalid(String) // a JSON Lines record that does not parse, verbatim
    }

    /// How a parent reaches a child.
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    let value: Value
    /// nil for the root.
    private(set) var step: Step?
    private(set) weak var parent: JSONNode?
    private(set) var children: [JSONNode] = []

    init(_ value: Value) { self.value = value }

    func add(_ child: JSONNode, _ step: Step) {
        child.step = step
        child.parent = self
        children.append(child)
    }

    var isContainer: Bool { value == .object || value == .array }

    /// From the root down to the parent.
    var ancestors: [JSONNode] {
        var chain: [JSONNode] = []
        var n = parent
        while let p = n { chain.append(p); n = p.parent }
        return chain.reversed()
    }

    /// Every node below this one, parents before children, in file order.
    var descendants: [JSONNode] {
        var out: [JSONNode] = []
        var stack = Array(children.reversed())
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: n.children.reversed())
        }
        return out
    }

    var steps: [Step] { (ancestors.dropFirst() + [self]).compactMap(\.step) }

    func node(at steps: [Step]) -> JSONNode? {
        var n = self
        for s in steps {
            switch s {
            case .index(let i):
                guard n.value == .array, n.children.indices.contains(i) else { return nil }
                n = n.children[i]
            case .key:
                guard n.value == .object, let c = n.children.first(where: { $0.step == s }) else { return nil }
                n = c
            }
        }
        return n
    }

    /// The node's address as a jq filter: `.`, `.items[2].id`, `.["odd key"]`.
    var path: String {
        var s = ""
        for step in steps {
            switch step {
            case .key(let k) where Self.isIdentifier(k): s += "." + k
            case .key(let k): s += (s.isEmpty ? "." : "") + "[" + Self.quote(k) + "]"
            case .index(let i): s += (s.isEmpty ? "." : "") + "[\(i)]"
            }
        }
        return s.isEmpty ? "." : s
    }

    // MARK: - Text

    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// A key as the tree shows it: bare when it reads as a name, quoted otherwise.
    static func keyLabel(_ k: String) -> String { isIdentifier(k) ? k : quote(k) }

    /// A JSON string literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// A scalar as JSON (strings quoted); containers have none.
    var literal: String {
        switch value {
        case .string(let s): return Self.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .invalid(let s): return s
        case .object, .array: return ""
        }
    }

    /// "3 keys" / "1 item"; nil for scalars.
    var summary: String? {
        let n = children.count
        switch value {
        case .object: return "\(n) \(n == 1 ? "key" : "keys")"
        case .array: return "\(n) \(n == 1 ? "item" : "items")"
        default: return nil
        }
    }

    /// The value as JSON. `indent` nil: on one line; otherwise pretty-printed from that depth.
    /// `limit` stops writing soon after that many bytes (for previews of huge values).
    func json(indent: Int? = 0, limit: Int = .max) -> String {
        var out = ""
        write(&out, indent, limit)
        return out
    }

    private func write(_ out: inout String, _ indent: Int?, _ limit: Int) {
        guard isContainer else { out += literal; return }
        let (open, close) = value == .object ? ("{", "}") : ("[", "]")
        guard !children.isEmpty else { out += open + close; return }
        func newline(_ depth: Int) { out += "\n" + String(repeating: " ", count: depth * 2) }
        out += open
        for (i, c) in children.enumerated() {
            if out.utf8.count > limit { return }
            if i > 0 { out += indent == nil ? ", " : "," }
            if let indent { newline(indent + 1) }
            if case .key(let k) = c.step { out += Self.quote(k) + ": " }
            c.write(&out, indent.map { $0 + 1 }, limit)
        }
        if let indent { newline(indent) }
        out += close
    }

    /// What `y` copies: a string's content, a scalar as written, a container as pretty JSON.
    var copyText: String {
        switch value {
        case .string(let s), .invalid(let s): return s
        default: return json()
        }
    }

    /// A folded container at a glance: `{id: 1, name: "Alice", …}`, about `limit` characters.
    func preview(limit: Int = 80) -> String {
        var out = ""
        writePreview(&out, limit)
        return out
    }

    private func writePreview(_ out: inout String, _ limit: Int) {
        guard isContainer else {
            if case .string(let s) = value, s.count > 40 { out += Self.quote(String(s.prefix(40)) + "…") } else { out += literal }
            return
        }
        out += value == .object ? "{" : "["
        for (i, c) in children.enumerated() {
            if i > 0 { out += ", " }
            if out.count >= limit { out += "…"; break }
            if case .key(let k) = c.step { out += Self.keyLabel(k) + ": " }
            c.writePreview(&out, limit)
        }
        out += value == .object ? "}" : "]"
    }

    // MARK: - As a table

    /// An array of objects (an API's list of records, a JSON Lines file): it reads as a table.
    var isTabular: Bool { value == .array && !children.isEmpty && children.allSatisfy { $0.value == .object } }

    /// One row per element and one column per key, in the order the keys first appear.
    /// Nested values are written on one line; `null` and missing keys are empty cells.
    func table() -> TableData {
        var header: [String] = []
        var column: [String: Int] = [:]
        let records = children.prefix(CSV.maxRows)
        for record in records {
            for c in record.children {
                if case .key(let k) = c.step, column[k] == nil {
                    column[k] = header.count
                    header.append(k)
                }
            }
        }
        let rows = records.map { record -> [String] in
            var row = [String](repeating: "", count: header.count)
            var seen = Set<Int>()
            for c in record.children {
                guard case .key(let k) = c.step, let i = column[k], seen.insert(i).inserted else { continue }
                switch c.value {
                case .string(let s), .invalid(let s): row[i] = s
                case .null: row[i] = ""
                case .object, .array: row[i] = c.json(indent: nil)
                default: row[i] = c.literal
                }
            }
            return row
        }
        var t = TableData(header: header, rows: rows, totalRows: children.count + 1)
        t.inferTypes()
        return t
    }
}

/// Strict JSON → `JSONNode`. Anything else (comments, trailing commas) is not JSON here, and
/// the file is then shown as text.
enum JSONTree {
    /// Bigger files are shown as text: a node per value costs far more memory than the bytes.
    static let maxBytes = 32 << 20
    static let maxDepth = 512

    static func parse(_ text: String) -> JSONNode? {
        guard text.utf8.count <= maxBytes else { return nil }
        var p = Parser(bytes: Array(text.utf8))
        return p.document()
    }

    /// JSON Lines: an array with one element per non-empty line; a line that is not JSON is
    /// kept as an `.invalid` node so it stays visible in place.
    static func parseLines(_ text: String) -> JSONNode? {
        guard text.utf8.count <= maxBytes else { return nil }
        let root = JSONNode(.array)
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            var p = Parser(bytes: Array(s.utf8))
            root.add(p.document() ?? JSONNode(.invalid(s)), .index(root.children.count))
        }
        return root
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        private func at(_ c: Character) -> Bool { i < bytes.count && bytes[i] == c.asciiValue! }

        mutating func document() -> JSONNode? {
            skip()
            guard let v = value(depth: 0) else { return nil }
            skip()
            return i == bytes.count ? v : nil
        }

        private mutating func skip() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        private mutating func value(depth: Int) -> JSONNode? {
            guard i < bytes.count, depth < JSONTree.maxDepth else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                let node = JSONNode(.object)
                skip()
                if at("}") { i += 1; return node }
                while true {
                    skip()
                    guard let key = string() else { return nil }
                    skip()
                    guard at(":") else { return nil }
                    i += 1
                    skip()
                    guard let v = value(depth: depth + 1) else { return nil }
                    node.add(v, .key(key))
                    skip()
                    if at(",") { i += 1 } else if at("}") { i += 1; return node } else { return nil }
                }
            case UInt8(ascii: "["):
                i += 1
                let node = JSONNode(.array)
                skip()
                if at("]") { i += 1; return node }
                while true {
                    skip()
                    guard let v = value(depth: depth + 1) else { return nil }
                    node.add(v, .index(node.children.count))
                    skip()
                    if at(",") { i += 1 } else if at("]") { i += 1; return node } else { return nil }
                }
            case UInt8(ascii: "\""): return string().map { JSONNode(.string($0)) }
            case UInt8(ascii: "t"): return word("true") ? JSONNode(.bool(true)) : nil
            case UInt8(ascii: "f"): return word("false") ? JSONNode(.bool(false)) : nil
            case UInt8(ascii: "n"): return word("null") ? JSONNode(.null) : nil
            default: return number()
            }
        }

        private mutating func word(_ w: String) -> Bool {
            let u = Array(w.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<(i + u.count)]) == u else { return false }
            i += u.count
            return true
        }

        /// `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`, kept as written.
        private mutating func number() -> JSONNode? {
            let start = i
            func digit(_ j: Int) -> Bool { j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 }
            if at("-") { i += 1 }
            guard digit(i) else { return nil }
            if at("0") { i += 1 } else { while digit(i) { i += 1 } }
            if at("."), digit(i + 1) {
                i += 1
                while digit(i) { i += 1 }
            }
            if at("e") || at("E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
                guard digit(j) else { return nil }
                i = j
                while digit(i) { i += 1 }
            }
            return JSONNode(.number(String(decoding: bytes[start..<i], as: UTF8.self)))
        }

        private mutating func string() -> String? {
            guard at("\"") else { return nil }
            i += 1
            let start = i
            // Most strings have no escapes: find the closing quote and decode in one go.
            while i < bytes.count, bytes[i] != UInt8(ascii: "\""), bytes[i] != UInt8(ascii: "\\") { i += 1 }
            guard i < bytes.count else { return nil }
            if at("\"") {
                defer { i += 1 }
                return String(decoding: bytes[start..<i], as: UTF8.self)
            }
            var out = Array(bytes[start..<i])
            while i < bytes.count {
                let c = bytes[i]
                i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard c == UInt8(ascii: "\\") else { out.append(c); continue }
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    // A surrogate pair is one character; a lone surrogate becomes U+FFFD.
                    if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
                default: return nil
                }
            }
            return nil
        }

        private mutating func hex4() -> UInt32? {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else { return nil }
            i += 4
            return v
        }
    }
}

/// The JSON tree of a file, parsed once for whoever shows it (the tree, the table, and the
/// controller that picks between them): the last file read is kept until it changes on disk.
enum JSONSource {
    private static var cached: (path: String, modified: Date?, size: Int?, root: JSONNode?)?

    /// nil: not a file, unreadable, too large, or not valid JSON.
    static func read(_ source: Source, _ kind: FileKind) -> JSONNode? {
        guard let url = source.url, kind.isJSON else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = attributes?[.size] as? Int
        if let c = cached, c.path == url.path, c.modified == modified, c.size == size { return c.root }
        var root: JSONNode?
        if (size ?? 0) <= JSONTree.maxBytes, let data = FileManager.default.contents(atPath: url.path) {
            let text = String(decoding: data, as: UTF8.self)
            if case .jsonl = kind { root = JSONTree.parseLines(text) } else { root = JSONTree.parse(text) }
        }
        cached = (url.path, modified, size, root)
        return root
    }
}
