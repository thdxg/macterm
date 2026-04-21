import Foundation
@testable import Macterm
import Testing

@MainActor
struct WorkspaceTests {
    private func makeWorkspace() -> Workspace {
        Workspace(projectID: UUID(), projectPath: "/tmp")
    }

    @Test
    func init_creates_one_tab_and_selects_it() {
        let ws = makeWorkspace()
        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == ws.tabs[0].id)
    }

    @Test
    func createTab_appends_and_selects() {
        let ws = makeWorkspace()
        let original = ws.tabs[0].id
        let new = ws.createTab(projectPath: "/tmp")
        #expect(ws.tabs.count == 2)
        #expect(ws.activeTabID == new.id)
        #expect(original != new.id)
    }

    @Test
    func closeTab_active_selects_most_recent_from_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        let t3 = ws.createTab(projectPath: "/tmp").id
        #expect(ws.activeTabID == t3)
        ws.closeTab(t3)
        #expect(ws.activeTabID == t2)
        #expect(!ws.tabs.contains(where: { $0.id == t3 }))
        _ = t1
    }

    @Test
    func closeTab_nonactive_leaves_active_alone() {
        let ws = makeWorkspace()
        let t2 = ws.createTab(projectPath: "/tmp").id
        let before = ws.activeTabID
        ws.closeTab(ws.tabs[0].id)
        #expect(ws.activeTabID == before)
        _ = t2
    }

    @Test
    func closeTab_invalid_id_is_noop() {
        let ws = makeWorkspace()
        ws.closeTab(UUID())
        #expect(ws.tabs.count == 1)
    }

    @Test
    func closeTab_empties_activeTabID_when_no_tabs_left() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ws.closeTab(only)
        #expect(ws.activeTabID == nil)
    }

    @Test
    func selectNextTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        #expect(ws.activeTabID == t2)
        ws.selectNextTab()
        #expect(ws.activeTabID == t1)
        ws.selectNextTab()
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectPreviousTab_wraps() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.selectPreviousTab()
        #expect(ws.activeTabID == t1)
        ws.selectPreviousTab()
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectNextTab_single_tab_is_noop() {
        let ws = makeWorkspace()
        let only = ws.tabs[0].id
        ws.selectNextTab()
        #expect(ws.activeTabID == only)
    }

    @Test
    func selectTab_ignores_unknown_id() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ws.selectTab(UUID())
        #expect(ws.activeTabID == before)
    }

    @Test
    func recencyOrder_active_first_then_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        let t3 = ws.createTab(projectPath: "/tmp").id
        ws.selectTab(t1)
        let order = ws.recencyOrder()
        #expect(order.first == t1)
        #expect(order.count == 3)
        _ = (t2, t3)
    }

    @Test
    func recencyOrder_includes_unvisited_tabs_at_tail() {
        let ws = makeWorkspace()
        _ = ws.createTab(projectPath: "/tmp")
        _ = ws.createTab(projectPath: "/tmp")
        let order = ws.recencyOrder()
        #expect(Set(order) == Set(ws.tabs.map(\.id)))
    }

    @Test
    func peekTab_does_not_record_history() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.peekTab(t1)
        #expect(ws.activeTabID == t1)
        ws.closeTab(t1)
        #expect(ws.activeTabID == t2)
    }

    @Test
    func selectTabByIndex_selects_tab_at_index() {
        let ws = makeWorkspace()
        _ = ws.createTab(projectPath: "/tmp")
        let t3 = ws.createTab(projectPath: "/tmp").id
        ws.selectTabByIndex(2)
        #expect(ws.activeTabID == t3)
    }

    @Test
    func selectTabByIndex_out_of_range_is_noop() {
        let ws = makeWorkspace()
        let before = ws.activeTabID
        ws.selectTabByIndex(99)
        #expect(ws.activeTabID == before)
    }

    @Test
    func reorderTabs_moves_tabs() {
        let ws = makeWorkspace()
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: "/tmp").id
        ws.reorderTabs(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(ws.tabs.map(\.id) == [t2, t1])
    }
}
