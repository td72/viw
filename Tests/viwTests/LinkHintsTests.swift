import AppKit
import Foundation
import Testing
@testable import viw

@Suite struct LinkHintsTests {
    @Test func oneLetterWhileTheHomeRowIsEnough() {
        #expect(LinkHints.labels(count: 0).isEmpty)
        #expect(LinkHints.labels(count: 3) == ["a", "s", "d"])
        #expect(LinkHints.labels(count: 9) == ["a", "s", "d", "f", "g", "h", "j", "k", "l"])
    }

    @Test func twoLettersWhenThereAreMore() {
        let labels = LinkHints.labels(count: 10)
        #expect(labels.count == 10)
        #expect(labels.allSatisfy { $0.count == 2 })
        #expect(Array(labels.prefix(3)) == ["aa", "sa", "da"])   // the first letter varies fastest
        #expect(labels[9] == "as")
        #expect(LinkHints.labels(count: 81).allSatisfy { $0.count == 2 })
        #expect(LinkHints.labels(count: 82).allSatisfy { $0.count == 3 })
    }

    @Test func uniqueAndNoLabelIsAPrefixOfAnother() {
        for count in [1, 9, 10, 50, 81, 82, 300] {
            let labels = LinkHints.labels(count: count)
            #expect(labels.count == count)
            #expect(Set(labels).count == count)
            #expect(labels.allSatisfy { $0.allSatisfy(LinkHints.alphabet.contains) })
            for a in labels {
                #expect(!labels.contains { $0 != a && $0.hasPrefix(a) })
            }
        }
    }

    @Test func otherAlphabets() {
        #expect(LinkHints.labels(count: 3, alphabet: "ab") == ["aa", "ba", "ab"])
        #expect(LinkHints.labels(count: 2, alphabet: "x") == ["x", "xx"])
        #expect(LinkHints.labels(count: 2, alphabet: "").isEmpty)
    }
}

@Suite @MainActor struct TextLinkHintTests {
    private func view(_ markdown: String) -> TextDocumentView {
        let v = TextDocumentView()
        v.load(source: .text(markdown, title: "t"), kind: .markdown, theme: Theme(), preserveScroll: false)
        return v
    }

    @Test func labelsTheLinksInSight() {
        let v = view("One [first](https://example.com/1), [second](#heading) and [third](other.md).\n\n"
            + String(repeating: "filler\n\n", count: 400) + "[far below](https://example.com/far)\n")
        #expect(v.hintLabels.isEmpty)
        v.filter()                                  // `f`
        #expect(v.hintLabels == ["a", "s", "d"])    // the link far below is out of sight
        v.scrollLines(1)                            // scrolling ends the hints
        #expect(v.hintLabels.isEmpty)
        v.scrollToTop()
        v.followLinkInNewTab()                      // `F`
        #expect(v.hintLabels == ["a", "s", "d"])
        v.load(source: .text("no links here\n", title: "t"), kind: .markdown, theme: Theme(), preserveScroll: false)
        #expect(v.hintLabels.isEmpty)
        v.filter()
        #expect(v.hintLabels.isEmpty)               // nothing to label
    }
}
