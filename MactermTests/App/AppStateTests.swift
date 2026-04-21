@testable import Macterm
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    // MARK: - Setup helpers

    /// Build an AppState with a temp-file workspace store so tests don't
    /// touch the user's real App Support data.
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp))
    }

    /// Create a project + workspace inside `state` and return the project.
    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    // MARK: - Splits

    func test_splitPane_adds_pane_and_focuses_it() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.splitPane(direction: .horizontal, projectID: p.id)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 2)
        XCTAssertNotEqual(tab.focusedPaneID, before)
    }

    func test_splitPane_no_focused_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        tab.focusedPaneID = nil
        state.splitPane(direction: .horizontal, projectID: p.id)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 1)
    }

    // MARK: - Close pane

    func test_closePane_last_pane_closes_the_whole_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try XCTUnwrap(state.workspaces[p.id])
        let originalTab = try XCTUnwrap(ws.activeTab)
        let onlyPane = try XCTUnwrap(originalTab.focusedPaneID)
        // Add a second tab so closing the original doesn't leave us with zero.
        _ = ws.createTab(projectPath: "/tmp")
        let otherTab = try XCTUnwrap(ws.activeTabID)

        // Focus the original tab, then close its only pane.
        ws.selectTab(originalTab.id)
        state.closePane(onlyPane, projectID: p.id)

        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabID, otherTab)
    }

    func test_closePane_middle_pane_removes_from_tree() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 2)
        let target = try XCTUnwrap(tab.focusedPaneID)
        state.closePane(target, projectID: p.id)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 1)
        XCTAssertNotEqual(tab.focusedPaneID, target)
    }

    /// Integration-level regression: HV-close on the active tab via AppState.
    func test_closePane_HV_close_regression() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)

        // Replace splitRoot with a known HV shape.
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        tab.splitRoot = tree
        tab.focusedPaneID = try XCTUnwrap(ids["l1"])

        try state.closePane(XCTUnwrap(ids["l1"]), projectID: p.id)

        XCTAssertEqual(render(tab.splitRoot, ids: ids), "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        XCTAssertEqual(remaining, try [XCTUnwrap(ids["r1"]), XCTUnwrap(ids["r2"])])
    }

    func test_closePane_from_non_active_tab_still_works() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try XCTUnwrap(state.workspaces[p.id])
        let originalTab = try XCTUnwrap(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let targetInOriginal = try XCTUnwrap(originalTab.focusedPaneID)

        // Switch to a new tab, then close a pane on the (now non-active) original.
        _ = ws.createTab(projectPath: "/tmp")
        XCTAssertNotEqual(ws.activeTabID, originalTab.id)
        state.closePane(targetInOriginal, projectID: p.id)
        XCTAssertEqual(originalTab.splitRoot.allPanes().count, 1)
    }

    // MARK: - Focus navigation

    func test_focusPaneInDirection_right_in_horizontal_split() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = try XCTUnwrap(ids["a"])
        state.focusPaneInDirection(.right, projectID: p.id)
        XCTAssertEqual(tab.focusedPaneID, ids["b"])
    }

    func test_focusPaneInDirection_no_neighbor_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.focusPaneInDirection(.right, projectID: p.id)
        XCTAssertEqual(tab.focusedPaneID, before)
    }

    // MARK: - Project lifecycle

    func test_removeProject_drops_workspace_and_clears_active_when_matching() {
        let state = makeAppState()
        let p = seedProject(state)
        XCTAssertEqual(state.activeProjectID, p.id)
        state.removeProject(p.id)
        XCTAssertNil(state.workspaces[p.id])
        XCTAssertNil(state.activeProjectID)
    }

    func test_removeProject_leaves_active_alone_when_not_matching() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // p2 is active; remove p1.
        state.removeProject(p1.id)
        XCTAssertEqual(state.activeProjectID, p2.id)
    }

    // MARK: - requestClosePane / pendingClosePane

    func test_requestClosePane_without_running_process_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try XCTUnwrap(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try XCTUnwrap(tab.focusedPaneID)
        // No GhosttyTerminalNSView is ever created in tests, so needsConfirmQuit is false.
        state.requestClosePane(target, projectID: p.id)
        XCTAssertNil(state.pendingClosePane)
        XCTAssertEqual(tab.splitRoot.allPanes().count, 1)
    }
}
