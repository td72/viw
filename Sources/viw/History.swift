/// Back / forward stacks of one tab, like a browser's: following a link pushes where you
/// were, going back moves it to the forward stack, and following another link from there
/// drops the forward side. Generic so the logic is testable without a window.
struct NavigationHistory<Entry> {
    private(set) var back: [Entry] = []
    private(set) var forward: [Entry] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A link is being followed from `current`.
    mutating func push(_ current: Entry) {
        back.append(current)
        forward.removeAll()
    }

    /// Up to `n` steps back from `current`; nil when there is nowhere to go.
    mutating func goBack(_ n: Int = 1, from current: Entry) -> Entry? {
        Self.move(n, from: current, popping: &back, onto: &forward)
    }

    /// Up to `n` steps forward from `current`; nil when there is nowhere to go.
    mutating func goForward(_ n: Int = 1, from current: Entry) -> Entry? {
        Self.move(n, from: current, popping: &forward, onto: &back)
    }

    private static func move(_ n: Int, from current: Entry, popping: inout [Entry], onto: inout [Entry]) -> Entry? {
        var here = current
        var moved = false
        for _ in 0..<max(n, 0) {
            guard let next = popping.popLast() else { break }
            onto.append(here)
            here = next
            moved = true
        }
        return moved ? here : nil
    }
}
