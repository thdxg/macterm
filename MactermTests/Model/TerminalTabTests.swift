@testable import Macterm
import XCTest

@MainActor
final class TerminalTabTests: XCTestCase {
    /// Build a TerminalTab from a TreeBuilder spec by constructing the tab, then
    /// replacing its splitRoot. Auto-tiling is off by default in Preferences, so
    /// no need to worry about rebalancing in these tests unless explicitly set.
    private func makeTab(_ spec: TreeSpec, focused: String? = nil) -> (TerminalTab, [String: UUID]) {
        let (tree, ids) = build(spec)
        let tab = TerminalTab(projectPath: "/")
        tab.splitRoot = tree
        tab.focusedPaneID = focused.flatMap { ids[$0] } ?? tree.allPanes().first?.id
        tab.paneFocusHistory = RecencyStack(limit: 20)
        return (tab, ids)
    }

    // MARK: - focusPane

    func test_focusPane_updates_history_on_switch() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(XCTUnwrap(ids["b"]))
        XCTAssertEqual(tab.focusedPaneID, ids["b"])
        XCTAssertEqual(tab.paneFocusHistory.items.first, ids["a"])
    }

    func test_focusPane_same_pane_is_noop() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(XCTUnwrap(ids["a"]))
        XCTAssertTrue(tab.paneFocusHistory.isEmpty)
    }

    // MARK: - nextFocusAfterClose

    func test_nextFocusAfterClose_prefers_most_recent_valid() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        try tab.focusPane(XCTUnwrap(ids["b"])) // history: [a]
        try tab.focusPane(XCTUnwrap(ids["c"])) // history: [b, a]
        // Simulate c being about to be closed — ask who should take focus.
        // nextFocusAfterClose looks at the tree and history; c still in tree.
        // After removing c from the tree, the answer should be b.
        tab.splitRoot = try XCTUnwrap(try tab.splitRoot.removing(paneID: XCTUnwrap(ids["c"])))
        let next = tab.nextFocusAfterClose()
        XCTAssertEqual(next, ids["b"])
    }

    func test_nextFocusAfterClose_falls_back_to_first_pane_when_history_empty() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        // No history.
        let next = tab.nextFocusAfterClose()
        XCTAssertNotNil(next)
        // Should be one of the existing panes.
        let all = Set(tab.splitRoot.allPanes().map(\.id))
        XCTAssertTrue(try all.contains(XCTUnwrap(next)))
        _ = ids
    }

    // MARK: - split

    func test_split_focuses_new_pane() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        let newID = try tab.split(paneID: XCTUnwrap(ids["a"]), direction: .horizontal)
        XCTAssertNotNil(newID)
        XCTAssertEqual(tab.focusedPaneID, newID)
    }

    func test_split_pushes_old_focus_to_history() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        _ = try tab.split(paneID: XCTUnwrap(ids["a"]), direction: .horizontal)
        XCTAssertEqual(tab.paneFocusHistory.items.first, ids["a"])
    }

    func test_split_nonexistent_pane_is_noop() {
        let (tab, _) = makeTab(pane("a"), focused: "a")
        let originalFocus = tab.focusedPaneID
        let newID = tab.split(paneID: UUID(), direction: .horizontal)
        XCTAssertNil(newID)
        XCTAssertEqual(tab.focusedPaneID, originalFocus)
    }

    // MARK: - resize

    func test_resize_without_focused_pane_is_noop() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")), focused: "a")
        tab.focusedPaneID = nil
        let before = tab.splitRoot
        tab.resize(.right, delta: 0.1)
        // Tree root reference unchanged (resize returns self if nothing matched).
        // We can't compare directly, so check ratio.
        if case let .split(b1) = before, case let .split(b2) = tab.splitRoot {
            XCTAssertEqual(b1.ratio, b2.ratio, accuracy: 0.0001)
        }
    }

    func test_resize_adjusts_ratio_of_focused_ancestor() {
        let (tab, _) = makeTab(H(pane("a"), pane("b"), ratio: 0.5), focused: "a")
        tab.resize(.right, delta: 0.1)
        if case let .split(b) = tab.splitRoot {
            XCTAssertEqual(b.ratio, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("expected split root")
        }
    }

    // MARK: - removePane

    func test_removePane_only_pane_returns_onlyPaneLeft() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        XCTAssertEqual(try tab.removePane(XCTUnwrap(ids["a"])), .onlyPaneLeft)
    }

    func test_removePane_middle_reshapes_tree_and_advances_focus() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        try tab.focusPane(XCTUnwrap(ids["b"])) // history: [a], focused: b
        XCTAssertEqual(try tab.removePane(XCTUnwrap(ids["b"])), .removed)
        XCTAssertEqual(render(tab.splitRoot, ids: ids), "a")
        // Focus moves to the only survivor via history.
        XCTAssertEqual(tab.focusedPaneID, ids["a"])
    }

    func test_removePane_of_unfocused_leaves_focus_alone() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        XCTAssertEqual(try tab.removePane(XCTUnwrap(ids["b"])), .removed)
        XCTAssertEqual(tab.focusedPaneID, ids["a"])
    }

    func test_removePane_notFound_is_noop() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")), focused: "a")
        XCTAssertEqual(tab.removePane(UUID()), .notFound)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 2)
    }

    func test_removePane_prunes_history() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        try tab.focusPane(XCTUnwrap(ids["b"])) // history: [a]
        try tab.focusPane(XCTUnwrap(ids["c"])) // history: [b, a]
        XCTAssertEqual(try tab.removePane(XCTUnwrap(ids["b"])), .removed)
        XCTAssertFalse(try tab.paneFocusHistory.items.contains(XCTUnwrap(ids["b"])))
    }

    /// Regression: `H(l1, V(r1, r2))`, close `l1` → must become `V(r1, r2)`
    /// with the original panes intact.
    func test_removePane_HV_close_regression() throws {
        let (tab, ids) = makeTab(H(pane("l1"), V(pane("r1"), pane("r2"))), focused: "l1")
        XCTAssertEqual(try tab.removePane(XCTUnwrap(ids["l1"])), .removed)
        XCTAssertEqual(render(tab.splitRoot, ids: ids), "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        XCTAssertEqual(remaining, try [XCTUnwrap(ids["r1"]), XCTUnwrap(ids["r2"])])
        // Focus moves to an existing pane.
        XCTAssertNotNil(tab.focusedPaneID)
        XCTAssertTrue(try remaining.contains(XCTUnwrap(tab.focusedPaneID)))
    }
}
