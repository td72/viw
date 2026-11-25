import Testing
@testable import viw

@Suite struct JSONTreeTests {
    @Test func keepsOrderDuplicatesAndNumberSpelling() throws {
        let root = try #require(JSONTree.parse(#" {"b": 1.50, "a": [true, null, -0, 1e3], "b": "x"} "#))
        #expect(root.value == .object)
        #expect(root.children.map(\.step) == [.key("b"), .key("a"), .key("b")])
        #expect(root.children[0].value == .number("1.50"))
        #expect(root.children[1].children.map(\.value) == [.bool(true), .null, .number("-0"), .number("1e3")])
        #expect(root.json(indent: nil) == #"{"b": 1.50, "a": [true, null, -0, 1e3], "b": "x"}"#)
    }

    @Test func decodesEscapes() throws {
        let root = try #require(JSONTree.parse(#"["a\n\t\"\\\/", "éあ", "😀", "\ud83d"]"#))
        #expect(root.children.map(\.value) == [.string("a\n\t\"\\/"), .string("éあ"), .string("😀"), .string("\u{FFFD}")])
        #expect(root.children[0].literal == #""a\n\t\"\\/""#)
    }

    @Test func rejectsWhatIsNotJSON() {
        for text in ["", "{", "[1,]", "{\"a\":1,}", "{a: 1}", "01", "1.", "1e", "tru", "[1] 2", "// c\n{}", "'a'", "\"a"] {
            #expect(JSONTree.parse(text) == nil, "\(text)")
        }
        #expect(JSONTree.parse("  42 ")?.value == .number("42"))
        #expect(JSONTree.parse(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)) == nil)
    }

    @Test func paths() throws {
        let root = try #require(JSONTree.parse(#"{"items": [{"id": 1}, {"odd key": {"x": [0, 9]}}], "1st": true}"#))
        #expect(root.path == ".")
        #expect(root.descendants.map(\.path) == [
            ".items", ".items[0]", ".items[0].id", ".items[1]", #".items[1]["odd key"]"#,
            #".items[1]["odd key"].x"#, #".items[1]["odd key"].x[0]"#, #".items[1]["odd key"].x[1]"#, #".["1st"]"#,
        ])
        let deep = try #require(root.node(at: [.key("items"), .index(1), .key("odd key"), .key("x"), .index(1)]))
        #expect(deep.value == .number("9"))
        #expect(root.node(at: deep.steps) === deep)
        #expect(root.node(at: [.key("items"), .index(5)]) == nil)
        let nested = try #require(JSONTree.parse("[[1]]")) // parents are weak: the root has to be held
        #expect(nested.children[0].children[0].path == ".[0][0]")
    }

    @Test func prettyPrintAndPreview() throws {
        let root = try #require(JSONTree.parse(#"{"a": {"b": [1, "two"], "e": {}}, "s": "x"}"#))
        #expect(root.json() == """
        {
          "a": {
            "b": [
              1,
              "two"
            ],
            "e": {}
          },
          "s": "x"
        }
        """)
        #expect(root.preview() == #"{a: {b: [1, "two"], e: {}}, s: "x"}"#)
        #expect(root.preview(limit: 10) == #"{a: {b: [1, …], …}, …}"#)
        #expect(root.children[0].summary == "2 keys")
        #expect(root.children[1].copyText == "x")
        #expect(root.json(limit: 5).count < root.json().count)
    }

    @Test func arrayOfObjectsAsTable() throws {
        let root = try #require(JSONTree.parse(#"{"rows": [{"id": 1, "name": "a", "tags": ["x", "y"]}, {"name": null, "id": 2, "extra": {"k": true}}], "n": [1, 2]}"#))
        let rows = try #require(root.node(at: [.key("rows")]))
        #expect(rows.isTabular)
        #expect(!root.isTabular)
        #expect(root.node(at: [.key("n")])?.isTabular == false)
        let t = rows.table()
        #expect(t.header == ["id", "name", "tags", "extra"])
        #expect(t.rows == [["1", "a", #"["x", "y"]"#, ""], ["2", "", "", #"{"k": true}"#]])
        #expect(t.types.first?.isNumeric == true)
    }

    @Test func jsonLines() throws {
        let root = try #require(JSONTree.parseLines("{\"a\": 1}\n\n  {\"a\": 2, \"b\": \"x\"}\r\nnot json\n"))
        #expect(root.children.map(\.value) == [.object, .object, .invalid("not json")])
        #expect(root.children[1].children[1].path == ".[1].b")
        #expect(!root.isTabular)
        #expect(JSONTree.parseLines("{\"a\": 1}\n{\"b\": 2}\n")?.table().header == ["a", "b"])
    }
}
