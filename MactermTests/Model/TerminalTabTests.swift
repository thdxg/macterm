import Foundation
@testable import Macterm
import Testing

@MainActor
struct TerminalTabTests {
    /// Build a TerminalTab from a TreeBuilder spec by constructing the tab, then
    /// replacing its splitRoot.
    private func makeTab(_ spec: TreeSpec, focused: String? = nil) -> (TerminalTab, [String: UUID]) {
        let (tree, ids) = build(spec)
        let tab = TerminalTab(projectPath: "/")
        tab.splitRoot = tree
        tab.focusedPaneID = focused.flatMap { ids[$0] } ?? tree.allPanes().first?.id
        tab.paneFocusHistory = RecencyStack(limit: 20)
        return (tab, ids)
    }

    // MARK: - focusPane

    @Test
    func focusPane_updates_history_on_switch() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(#require(ids["b"]))
        #expect(tab.focusedPaneID == ids["b"])
        #expect(tab.paneFocusHistory.items.first == ids["a"])
    }

    @Test
    func focusPane_same_pane_is_noop() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(#require(ids["a"]))
        #expect(tab.paneFocusHistory.isEmpty)
    }

    // MARK: - nextFocusAfterClose

    @Test
    func nextFocusAfterClose_prefers_most_recent_valid() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        try tab.focusPane(#require(ids["b"])) // history: [a]
        try tab.focusPane(#require(ids["c"])) // history: [b, a]
        let cID = try #require(ids["c"])
        tab.splitRoot = try #require(tab.splitRoot.removing(paneID: cID))
        let next = tab.nextFocusAfterClose()
        #expect(next == ids["b"])
    }

    @Test
    func nextFocusAfterClose_falls_back_to_first_pane_when_history_empty() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let next = tab.nextFocusAfterClose()
        #expect(next != nil)
        let all = Set(tab.splitRoot.allPanes().map(\.id))
        #expect(try all.contains(#require(next)))
        _ = ids
    }

    // MARK: - split

    @Test
    func split_focuses_new_pane() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        let newID = try tab.split(paneID: #require(ids["a"]), direction: .horizontal)
        #expect(newID != nil)
        #expect(tab.focusedPaneID == newID)
    }

    @Test
    func split_pushes_old_focus_to_history() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        _ = try tab.split(paneID: #require(ids["a"]), direction: .horizontal)
        #expect(tab.paneFocusHistory.items.first == ids["a"])
    }

    @Test
    func split_nonexistent_pane_is_noop() {
        let (tab, _) = makeTab(pane("a"), focused: "a")
        let originalFocus = tab.focusedPaneID
        let newID = tab.split(paneID: UUID(), direction: .horizontal)
        #expect(newID == nil)
        #expect(tab.focusedPaneID == originalFocus)
    }

    // MARK: - resize

    @Test
    func resize_without_focused_pane_is_noop() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")), focused: "a")
        tab.focusedPaneID = nil
        let before = tab.splitRoot
        tab.resize(.right, delta: 0.1)
        if case let .split(b1) = before, case let .split(b2) = tab.splitRoot {
            #expect(abs(b1.ratio - b2.ratio) < 0.0001)
        }
    }

    @Test
    func resize_adjusts_ratio_of_focused_ancestor() {
        let (tab, _) = makeTab(H(pane("a"), pane("b"), ratio: 0.5), focused: "a")
        tab.resize(.right, delta: 0.1)
        if case let .split(b) = tab.splitRoot {
            #expect(abs(b.ratio - 0.6) < 0.0001)
        } else {
            Issue.record("expected split root")
        }
    }

    // MARK: - removePane

    @Test
    func removePane_only_pane_returns_onlyPaneLeft() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        #expect(try tab.removePane(#require(ids["a"])) == .onlyPaneLeft)
    }

    @Test
    func removePane_middle_reshapes_tree_and_advances_focus() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(#require(ids["b"])) // history: [a], focused: b
        #expect(try tab.removePane(#require(ids["b"])) == .removed)
        #expect(render(tab.splitRoot, ids: ids) == "a")
        #expect(tab.focusedPaneID == ids["a"])
    }

    @Test
    func removePane_of_unfocused_leaves_focus_alone() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        #expect(try tab.removePane(#require(ids["b"])) == .removed)
        #expect(tab.focusedPaneID == ids["a"])
    }

    @Test
    func removePane_notFound_is_noop() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")), focused: "a")
        #expect(tab.removePane(UUID()) == .notFound)
        #expect(tab.splitRoot.allPanes().count == 2)
    }

    @Test
    func removePane_prunes_history() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        try tab.focusPane(#require(ids["b"])) // history: [a]
        try tab.focusPane(#require(ids["c"])) // history: [b, a]
        #expect(try tab.removePane(#require(ids["b"])) == .removed)
        #expect(try !tab.paneFocusHistory.items.contains(#require(ids["b"])))
    }

    /// Regression: `H(l1, V(r1, r2))`, close `l1` → must become `V(r1, r2)`
    /// with the original panes intact.
    @Test
    func removePane_HV_close_regression() throws {
        let (tab, ids) = makeTab(H(pane("l1"), V(pane("r1"), pane("r2"))), focused: "l1")
        #expect(try tab.removePane(#require(ids["l1"])) == .removed)
        #expect(render(tab.splitRoot, ids: ids) == "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        #expect(try remaining == [#require(ids["r1"]), #require(ids["r2"])])
        #expect(tab.focusedPaneID != nil)
        #expect(try remaining.contains(#require(tab.focusedPaneID)))
    }
}
