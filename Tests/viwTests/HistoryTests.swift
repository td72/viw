import Testing
@testable import viw

@Suite struct NavigationHistoryTests {
    @Test func emptyHistoryGoesNowhere() {
        var h = NavigationHistory<String>()
        #expect(h.goBack(from: "a") == nil)
        #expect(h.goForward(from: "a") == nil)
        #expect(!h.canGoBack && !h.canGoForward)
    }

    @Test func backAndForwardRoundTrip() {
        var h = NavigationHistory<String>()
        h.push("a")                               // a → b
        h.push("b")                               // b → c
        #expect(h.goBack(from: "c") == "b")
        #expect(h.goBack(from: "b") == "a")
        #expect(h.goBack(from: "a") == nil)
        #expect(h.goForward(from: "a") == "b")
        #expect(h.goForward(from: "b") == "c")
        #expect(h.goForward(from: "c") == nil)
        #expect(h.back == ["a", "b"])
    }

    @Test func followingALinkDropsTheForwardSide() {
        var h = NavigationHistory<String>()
        h.push("a")
        h.push("b")
        #expect(h.goBack(from: "c") == "b")
        h.push("b")                               // b → d
        #expect(!h.canGoForward)
        #expect(h.goBack(from: "d") == "b")
        #expect(h.goBack(from: "b") == "a")
    }

    @Test func countsStopAtTheEnd() {
        var h = NavigationHistory<String>()
        h.push("a")
        h.push("b")
        h.push("c")
        #expect(h.goBack(2, from: "d") == "b")
        #expect(h.forward == ["d", "c"])
        #expect(h.goBack(5, from: "b") == "a")    // only one step left
        #expect(h.goForward(9, from: "a") == "d")
        #expect(h.back == ["a", "b", "c"])
    }
}
