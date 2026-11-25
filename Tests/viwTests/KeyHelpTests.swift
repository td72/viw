import Testing
@testable import viw

@Suite struct KeyHelpTests {
    @Test func keysAreWaysOfCounterpartsOfSequences() {
        let e = KeyHelp.Entry("g g / G | Home / End", "Top / bottom")
        #expect(e.groups == [[["g", "g"], ["G"]], [["Home"], ["End"]]])
        #expect(e.keysText == "gg / G   Home / End")
        #expect(KeyHelp.Entry("/", "Find").groups == [[["/"]]])                 // the key, not a separator
        #expect(KeyHelp.Entry("+ / -", "Zoom").groups == [[["+"], ["-"]]])
        #expect(KeyHelp.Entry("3 g t | ⌘3", "Tab 3").keysText == "3gt   ⌘3")
        #expect(KeyHelp.Entry("] ] / [ [", "Headings").keysText == "]] / [[")
        let plain = KeyHelp.Entry(plain: "click a link", "Follow the link")
        #expect(plain.groups.isEmpty)
        #expect(plain.keysText == "click a link")
    }

    @Test func filterLooksAtKeysActionsAndNotes() {
        let sections = [
            KeyHelp.Section(title: "Move", entries: [KeyHelp.Entry("j / k", "Line down / up"), KeyHelp.Entry("g g / G", "Top / bottom")]),
            KeyHelp.Section(title: "Copy", entries: [KeyHelp.Entry("y", "Copy the selection", "tables: the cell")]),
        ]
        #expect(KeyHelp.filter(sections, "").map(\.title) == ["Move", "Copy"])
        #expect(KeyHelp.filter(sections, "  ").count == 2)
        let top = KeyHelp.filter(sections, "TOP")
        #expect(top.map(\.title) == ["Move"])
        #expect(top[0].entries.map(\.keysText) == ["gg / G"])
        #expect(KeyHelp.filter(sections, "gg").first?.entries.count == 1)        // by key
        #expect(KeyHelp.filter(sections, "cell").map(\.title) == ["Copy"])       // by note
        #expect(KeyHelp.filter(sections, "move").first?.entries.count == 2)      // a title keeps its section whole
        #expect(KeyHelp.filter(sections, "zzz").isEmpty)
    }

    @Test func everySectionIsWellFormed() {
        for section in KeyHelp.all {
            #expect(!section.entries.isEmpty, "\(section.title)")
            for e in section.entries {
                #expect(!e.action.isEmpty && !e.keysText.isEmpty, "\(section.title)")
                // No key is empty, and the DSL's separators never end up inside a key.
                #expect(e.groups.joined().joined().allSatisfy { !$0.isEmpty && !$0.contains("|") }, "\(section.title): \(e.keysText)")
                #expect(e.plain == nil || e.groups.isEmpty)
            }
        }
    }

    @Test func plainTextListsKeysActionsAndNotes() {
        let text = KeyHelp.plainText([KeyHelp.Section(title: "Move", entries: [
            KeyHelp.Entry("j / k", "Line down / up"),
            KeyHelp.Entry("h / l | 0 / $", "Sideways", "tables: the column cursor"),
        ])])
        #expect(text == "  Move\n    j / k           Line down / up\n    h / l   0 / $   Sideways (tables: the column cursor)\n\n")
    }
}
