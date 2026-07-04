import Foundation
@testable import Macterm
import Testing

@MainActor
struct TerminalTabTests {
    /// Build a TerminalTab from a TreeBuilder spec by constructing the tab, then
    /// replacing its splitRoot.
    private func makeTab(_ spec: TreeSpec, focused: String? = nil) -> (TerminalTab, [String: UUID]) {
        let (tree, ids) = build(spec)
        let tab = TerminalTab(projectPath: "/", projectID: UUID())
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

    // MARK: - autoSplit

    @Test
    func autoSplit_creates_and_focuses_new_pane() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        let newID = try tab.autoSplit(paneID: #require(ids["a"]))
        #expect(newID != nil)
        #expect(tab.focusedPaneID == newID)
    }

    @Test
    func autoSplit_falls_back_to_horizontal_without_measurable_bounds() throws {
        // In headless tests the pane has no attached NSView, so bounds are zero
        // and the longer-axis heuristic resolves to a horizontal (left/right) split.
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        _ = try tab.autoSplit(paneID: #require(ids["a"]))
        guard case let .split(branch) = tab.splitRoot else {
            Issue.record("expected a split at the root")
            return
        }
        #expect(branch.direction == .horizontal)
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

    // MARK: - executionState

    @Test
    func executionState_prefers_running_then_done_then_idle() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        let bID = try #require(ids["b"])
        let cID = try #require(ids["c"])
        let b = try #require(tab.splitRoot.findPane(id: bID))
        let c = try #require(tab.splitRoot.findPane(id: cID))
        b.executionState = .done
        c.executionState = .running
        #expect(tab.executionState == .running)
        c.executionState = .idle
        #expect(tab.executionState == .done)
        b.executionState = .idle
        #expect(tab.executionState == .idle)
    }

    @Test
    func executionState_rawRenderOnlyPaneMakesTabRunning() throws {
        // The sidebar spinner reads the tab aggregate. If a raw-mode pane only
        // repaints through render callbacks, the pane and tab should still become
        // `.running`.
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let bID = try #require(ids["b"])
        let b = try #require(tab.splitRoot.findPane(id: bID))
        b.recordUserInteraction()
        b.applyForegroundRefresh(name: "btop", foregroundPID: 42, terminalInputIsRaw: true)

        simulateTerminalRender(
            for: b,
            name: "btop",
            foregroundPID: 42,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(tab.executionState == .running)
    }

    @Test
    func executionState_freshRawActivityOverridesStaleDone() throws {
        // A stale `.done` pane should not keep the tab in done/checkmark state
        // after a new raw foreground process emits activity.
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        let aID = try #require(ids["a"])
        let p = try #require(tab.splitRoot.findPane(id: aID))
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.applyForegroundRefresh(name: "zsh", foregroundPID: 43, foregroundIsShell: true)
        #expect(tab.executionState == .done)

        p.applyForegroundRefresh(name: "watch", foregroundPID: 44, terminalInputIsRaw: true)
        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))

        #expect(tab.executionState == .running)
    }

    // MARK: - toggleZoom

    @Test
    func toggleZoom_sets_and_clears_zoomedPaneID() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let aID = try #require(ids["a"])
        tab.toggleZoom(paneID: aID)
        #expect(tab.zoomedPaneID == aID)
        tab.toggleZoom(paneID: aID)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func toggleZoom_switches_focus_to_zoomed_pane() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let bID = try #require(ids["b"])
        tab.toggleZoom(paneID: bID)
        #expect(tab.zoomedPaneID == bID)
        #expect(tab.focusedPaneID == bID)
    }

    @Test
    func toggleZoom_unknown_pane_is_noop() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")), focused: "a")
        tab.toggleZoom(paneID: UUID())
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func split_while_zoomed_clears_zoom() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let aID = try #require(ids["a"])
        tab.toggleZoom(paneID: aID)
        #expect(tab.zoomedPaneID == aID)
        _ = tab.split(paneID: aID, direction: .horizontal)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func focusPane_while_zoomed_clears_zoom() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let aID = try #require(ids["a"])
        let bID = try #require(ids["b"])
        tab.toggleZoom(paneID: aID)
        #expect(tab.zoomedPaneID == aID)
        tab.focusPane(bID)
        #expect(tab.zoomedPaneID == nil)
        #expect(tab.focusedPaneID == bID)
    }

    @Test
    func focusPane_on_zoomed_pane_keeps_zoom() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "b")
        let aID = try #require(ids["a"])
        tab.toggleZoom(paneID: aID)
        #expect(tab.zoomedPaneID == aID)
        // re-focusing the already-zoomed pane is a no-op (same pane)
        tab.focusPane(aID)
        #expect(tab.zoomedPaneID == aID)
        #expect(tab.focusedPaneID == aID)
    }

    @Test
    func removing_zoomed_pane_clears_zoom() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let bID = try #require(ids["b"])
        tab.toggleZoom(paneID: bID)
        #expect(tab.zoomedPaneID == bID)
        #expect(tab.removePane(bID) == .removed)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func removePane_prunes_history() throws {
        let (tab, ids) = makeTab(H(pane("a"), H(pane("b"), pane("c"))), focused: "a")
        try tab.focusPane(#require(ids["b"])) // history: [a]
        try tab.focusPane(#require(ids["c"])) // history: [b, a]
        #expect(try tab.removePane(#require(ids["b"])) == .removed)
        #expect(try !tab.paneFocusHistory.items.contains(#require(ids["b"])))
    }

    // MARK: - movePane

    @Test
    func movePane_detaches_and_splits_destination() throws {
        let (tab, ids) = makeTab(H(pane("a"), V(pane("b"), pane("c"))), focused: "a")
        #expect(try tab.movePane(#require(ids["a"]), onto: #require(ids["c"]), zone: .right))
        #expect(render(tab.splitRoot, ids: ids) == "V(b, H(c, a))")
    }

    @Test
    func movePane_top_zone_places_pane_before_destination() throws {
        let (tab, ids) = makeTab(H(pane("a"), V(pane("b"), pane("c"))), focused: "a")
        #expect(try tab.movePane(#require(ids["a"]), onto: #require(ids["b"]), zone: .top))
        #expect(render(tab.splitRoot, ids: ids) == "V(V(a, b), c)")
    }

    @Test
    func movePane_reuses_pane_instance() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let aID = try #require(ids["a"])
        let before = try #require(tab.splitRoot.findPane(id: aID))
        #expect(try tab.movePane(aID, onto: #require(ids["b"]), zone: .bottom))
        #expect(tab.splitRoot.findPane(id: aID) === before)
    }

    @Test
    func movePane_onto_sibling_swaps_sides() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        #expect(try tab.movePane(#require(ids["a"]), onto: #require(ids["b"]), zone: .right))
        #expect(render(tab.splitRoot, ids: ids) == "H(b, a)")
    }

    @Test
    func movePane_focuses_moved_pane_and_clears_zoom() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "b")
        let aID = try #require(ids["a"])
        try tab.toggleZoom(paneID: #require(ids["b"]))
        #expect(try tab.movePane(aID, onto: #require(ids["b"]), zone: .top))
        #expect(tab.focusedPaneID == aID)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func movePane_onto_self_is_noop() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        let aID = try #require(ids["a"])
        #expect(!tab.movePane(aID, onto: aID, zone: .left))
        #expect(render(tab.splitRoot, ids: ids) == "H(a, b)")
    }

    @Test
    func movePane_only_pane_is_noop() throws {
        let (tab, ids) = makeTab(pane("a"), focused: "a")
        #expect(try !tab.movePane(#require(ids["a"]), onto: UUID(), zone: .left))
        #expect(render(tab.splitRoot, ids: ids) == "a")
    }

    @Test
    func movePane_unknown_source_or_destination_is_noop() throws {
        let (tab, ids) = makeTab(H(pane("a"), pane("b")), focused: "a")
        #expect(try !tab.movePane(UUID(), onto: #require(ids["b"]), zone: .left))
        #expect(try !tab.movePane(#require(ids["a"]), onto: UUID(), zone: .left))
        #expect(render(tab.splitRoot, ids: ids) == "H(a, b)")
    }

    // MARK: - autoTitle / sidebarTitle / customTitle

    @Test
    func sidebarTitle_returns_customTitle_when_set() {
        let (tab, _) = makeTab(pane("a"))
        tab.customTitle = "My Tab"
        #expect(tab.sidebarTitle == "My Tab")
    }

    @Test
    func sidebarTitle_falls_back_to_autoTitle_when_customTitle_nil() {
        let (tab, _) = makeTab(pane("a"))
        tab.customTitle = nil
        #expect(tab.sidebarTitle == tab.autoTitle)
    }

    @Test
    func autoTitle_is_unaffected_by_customTitle() {
        let (tab, _) = makeTab(pane("a"))
        let autoBeforeSet = tab.autoTitle
        tab.customTitle = "My Tab"
        #expect(tab.autoTitle == autoBeforeSet)
    }

    @Test
    func clearing_customTitle_restores_autoTitle_in_sidebarTitle() {
        let (tab, _) = makeTab(pane("a"))
        let auto = tab.autoTitle
        tab.customTitle = "My Tab"
        #expect(tab.sidebarTitle == "My Tab")
        tab.customTitle = nil
        #expect(tab.sidebarTitle == auto)
    }

    @Test
    func autoTitle_joins_multiple_pane_titles_with_separator() {
        let (tab, _) = makeTab(H(pane("a"), pane("b")))
        // Both panes have the same processTitle in a test environment, so we
        // just verify the separator is present and autoTitle has two segments.
        let parts = tab.autoTitle.components(separatedBy: " | ")
        #expect(parts.count == 2)
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

    private func simulateTerminalRender(
        for pane: Pane,
        name: String,
        foregroundPID: pid_t,
        foregroundIsShell: Bool = false,
        terminalInputIsRaw: Bool = false,
        at date: Date
    ) {
        if pane.executionState != .running {
            pane.applyForegroundRefresh(
                name: name,
                foregroundPID: foregroundPID,
                foregroundIsShell: foregroundIsShell,
                terminalInputIsRaw: terminalInputIsRaw
            )
        }
        pane.markTerminalActivity(at: date, kind: .render)
    }
}
