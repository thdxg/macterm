@testable import Macterm
import XCTest

@MainActor
final class WorkspaceTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        Workspace(projectID: UUID(), projectPath: "/tmp")
    }

    func test_init_creates_one_tab_and_selects_it() {
        let ws = makeWorkspace()
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.activeTabID, ws.tabs[0].id)
    }

    func test_createTab_appends_and_selects() {
        let ws = makeWorkspace()
        let original = ws.tabs[0].id
        let new = ws.createTab(projectPath: "/tmp")
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertEqual(ws.activeTabID, new.id)
        XCTAssertNotEqual(original, new.id)
    }

    func test_closeTab_active_selects_most_recent_from_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        let t3 = ws.createTab(projectPath: "/tmp").id
        XCTAssertEqual(ws.activeTabID, t3)
        ws.closeTab(t3)
        // Most recent previously active was t2.
        XCTAssertEqual(ws.activeTabID, t2)
        XCTAssertFalse(ws.tabs.contains(where: { $0.id == t3 }))
        _ = t1
    }

    func test_closeTab_nonactive_leaves_active_alone() {
        let ws = makeWorkspace()
        let t2 = ws.createTab(projectPath: "/tmp").id
        let before = ws.activeTabID
        ws.closeTab(ws.tabs[0].id)
        XCTAssertEqual(ws.activeTabID, before)
        _ = t2
    }

    func test_closeTab_invalid_id_is_noop() {
        let ws = makeWorkspace()
        ws.closeTab(UUID())
        XCTAssertEqual(ws.tabs.count, 1)
    }

    func test_closeTab_empties_activeTabID_when_no_tabs_left() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ws.closeTab(only)
        XCTAssertNil(ws.activeTabID)
    }

    func test_selectNextTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        XCTAssertEqual(ws.activeTabID, t2)
        ws.selectNextTab()
        XCTAssertEqual(ws.activeTabID, t1)
        ws.selectNextTab()
        XCTAssertEqual(ws.activeTabID, t2)
    }

    func test_selectPreviousTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.selectPreviousTab()
        XCTAssertEqual(ws.activeTabID, t1)
        ws.selectPreviousTab()
        XCTAssertEqual(ws.activeTabID, t2)
    }

    func test_selectNextTab_single_tab_is_noop() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ws.selectNextTab()
        XCTAssertEqual(ws.activeTabID, only)
    }

    func test_selectTab_ignores_unknown_id() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ws.selectTab(UUID())
        XCTAssertEqual(ws.activeTabID, before)
    }

    func test_recencyOrder_active_first_then_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        let t3 = ws.createTab(projectPath: "/tmp").id
        ws.selectTab(t1)
        // Now active: t1, history contains t3 then t2 (pushed in that order).
        let order = ws.recencyOrder()
        XCTAssertEqual(order.first, t1)
        XCTAssertEqual(order.count, 3)
    }

    func test_recencyOrder_includes_unvisited_tabs_at_tail() {
        let ws = makeWorkspace()
        _ = ws.createTab(projectPath: "/tmp")
        _ = ws.createTab(projectPath: "/tmp")
        let order = ws.recencyOrder()
        XCTAssertEqual(Set(order), Set(ws.tabs.map(\.id)))
    }

    func test_peekTab_does_not_record_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.peekTab(t1)
        XCTAssertEqual(ws.activeTabID, t1)
        // After peek, closing t1 should select t2 (only tab left).
        ws.closeTab(t1)
        XCTAssertEqual(ws.activeTabID, t2)
    }

    func test_selectTabByIndex_selects_tab_at_index() {
        let ws = makeWorkspace()
        _ = ws.createTab(projectPath: "/tmp")
        let t3 = ws.createTab(projectPath: "/tmp").id
        ws.selectTabByIndex(2)
        XCTAssertEqual(ws.activeTabID, t3)
    }

    func test_selectTabByIndex_out_of_range_is_noop() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ws.selectTabByIndex(99)
        XCTAssertEqual(ws.activeTabID, before)
    }

    func test_reorderTabs_moves_tabs() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.reorderTabs(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(ws.tabs.map(\.id), [t2, t1])
    }
}
