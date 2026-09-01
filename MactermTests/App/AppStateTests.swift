import CoreGraphics
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateTests {
    // MARK: - Setup helpers

    /// Build an AppState with a temp-file workspace store and a temp-dir
    /// project-file store so tests don't touch the user's real App Support
    /// data or `~/.config/macterm/projects`.
    private func makeAppState(
        store: WorkspaceStore? = nil,
        projectFiles: ProjectFileStore? = nil
    ) -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return AppState(
            workspaceStore: store ?? WorkspaceStore(fileURL: tmp),
            projectFiles: projectFiles ?? makeProjectFileStore()
        )
    }

    /// Fresh central project-file store rooted in a unique tempdir.
    private func makeProjectFileStore() -> ProjectFileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return ProjectFileStore(directoryURL: dir)
    }

    /// Create a project + workspace inside `state` and return the project.
    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    // MARK: - Splits

    @Test
    func splitPane_adds_pane_and_focuses_it() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 2)
        #expect(tab.focusedPaneID != before)
    }

    @Test
    func splitPane_no_focused_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        tab.focusedPaneID = nil
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func adaptiveBackgroundColor_updatesOwnedPaneOnly() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        let color = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        state.setAdaptiveBackgroundColor(color, paneID: pane.id, projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == color)

        let otherProject = seedProject(state, name: "other", path: "/tmp/other")
        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: otherProject.id)
        #expect(pane.adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: UUID(), projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == nil)
    }

    // MARK: - Close pane

    @Test
    func closePane_last_pane_closes_the_whole_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        let onlyPane = try #require(originalTab.focusedPaneID)
        // Add a second tab so closing the original doesn't leave us with zero.
        _ = ws.createTab(projectPath: "/tmp")
        let otherTab = try #require(ws.activeTabID)

        // Focus the original tab, then close its only pane.
        ws.selectTab(originalTab.id)
        state.closePane(onlyPane, projectID: p.id)

        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == otherTab)
    }

    @Test
    func closePane_middle_pane_removes_from_tree() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 2)
        let target = try #require(tab.focusedPaneID)
        state.closePane(target, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(tab.focusedPaneID != target)
    }

    /// Integration-level regression: HV-close on the active tab via AppState.
    @Test
    func closePane_HV_close_regression() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)

        // Replace splitRoot with a known HV shape.
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["l1"]

        try state.closePane(#require(ids["l1"]), projectID: p.id)

        #expect(render(tab.splitRoot, ids: ids) == "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        #expect(try remaining == [#require(ids["r1"]), #require(ids["r2"])])
    }

    @Test
    func closePane_from_non_active_tab_still_works() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let targetInOriginal = try #require(originalTab.focusedPaneID)

        // Switch to a new tab, then close a pane on the (now non-active) original.
        _ = ws.createTab(projectPath: "/tmp")
        #expect(ws.activeTabID != originalTab.id)
        state.closePane(targetInOriginal, projectID: p.id)
        #expect(originalTab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Move tab between projects

    @Test
    func moveTab_relocates_tab_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        // Give p1 a second tab so moving one away doesn't empty it.
        let moving = ws1.createTab(projectPath: "/tmp1")
        let staying = try #require(ws1.tabs.first?.id)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Source lost the tab; destination gained it (object reused, surfaces intact).
        #expect(ws1.tabs.map(\.id) == [staying])
        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == moving.id })
        // Destination is now active with the moved tab selected.
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == moving.id)
    }

    @Test
    func moveTab_leaves_source_workspace_empty_when_moving_its_only_tab() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let only = try #require(ws1.tabs.first?.id)

        state.moveTab(only, from: p1.id, to: p2.id, destPath: p2.path)

        #expect(ws1.tabs.isEmpty)
        #expect(ws1.activeTabID == nil)
        #expect(state.workspaces[p2.id]?.tabs.contains { $0.id == only } == true)
    }

    @Test
    func moveTab_creates_destination_workspace_when_absent() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let ws1 = try #require(state.workspaces[p1.id])
        let tab = ws1.createTab(projectPath: "/tmp1")
        // A project that's never been opened — no workspace yet.
        let p2 = Project(name: "p2", path: "/tmp2", sortOrder: 1)
        #expect(state.workspaces[p2.id] == nil)

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == tab.id })
    }

    @Test
    func moveTab_same_project_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let before = ws.tabs.map(\.id)
        try state.moveTab(#require(before.first), from: p.id, to: p.id, destPath: p.path)
        #expect(ws.tabs.map(\.id) == before)
    }

    @Test
    func moveTab_unknown_tab_is_noop() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws2Before = try #require(state.workspaces[p2.id]).tabs.count
        state.moveTab(UUID(), from: p1.id, to: p2.id, destPath: p2.path)
        #expect(state.workspaces[p2.id]?.tabs.count == ws2Before)
    }

    // MARK: - Merge a tab into the workspace's active tab (#227)

    @Test
    func mergeTab_at_pane_target_splits_in_zone_direction() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        let destPane = try #require(destTab.splitRoot.allPanes().first?.id)
        let sourceTab = ws.createTab(projectPath: p.path)
        let sourcePane = try #require(sourceTab.splitRoot.allPanes().first?.id)
        ws.selectTab(destTab.id)

        state.mergeTab(sourceTab.id, from: p.id, at: .pane(destPane, .top), inProject: p.id)

        #expect(ws.tabs.map(\.id) == [destTab.id])
        // .top means the source lands first in a vertical split.
        #expect(destTab.splitRoot.allPanes().map(\.id) == [sourcePane, destPane])
        guard case let .split(branch) = destTab.splitRoot else {
            Issue.record("expected a split root")
            return
        }
        #expect(branch.direction == .vertical)
    }

    @Test
    func mergeTab_at_rootEdge_equalizes_to_thirds() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let sourceTab = ws.createTab(projectPath: p.path)
        ws.selectTab(destTab.id)

        state.mergeTab(sourceTab.id, from: p.id, at: .rootEdge(.left), inProject: p.id)

        // Side-by-side-by-side: every column takes an even third.
        let frames = destTab.splitRoot.paneFrames()
        #expect(frames.count == 3)
        for frame in frames.values {
            #expect(abs(frame.width - 1.0 / 3.0) < 0.001)
        }
    }

    @Test
    func mergeTab_when_active_tab_is_source_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.mergeTab(tab.id, from: p.id, at: .rootEdge(.bottom), inProject: p.id)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Separate panes (#227)

    @Test
    func separateTabPanes_gives_each_pane_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        state.splitPane(direction: .vertical, projectID: p.id)
        let panes = tab.splitRoot.allPanes().map(\.id)
        #expect(panes.count == 3)

        state.separateTabPanes(tab.id, projectID: p.id)

        // One tab per pane, inserted right after the source in tree order;
        // the source keeps the first pane and stays selected.
        #expect(ws.tabs.count == 3)
        #expect(ws.tabs.first?.id == tab.id)
        #expect(tab.splitRoot.allPanes().map(\.id) == [panes[0]])
        #expect(tab.focusedPaneID == panes[0])
        #expect(ws.tabs.map { $0.splitRoot.allPanes().map(\.id) } == panes.map { [$0] })
        #expect(ws.activeTabID == tab.id)
    }

    @Test
    func separateTabPanes_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.separateTabPanes(tab.id, projectID: p.id)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Separate one pane into its own tab (Separate Current Pane)

    @Test
    func separatePane_splits_the_pane_into_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let original = try #require(tab.focusedPaneID)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let dragged = try #require(tab.focusedPaneID)
        tab.zoomedPaneID = dragged

        state.separatePane(dragged, toProject: p.id, destPath: p.path)

        // The source tab keeps its remaining pane, exits the stale zoom, and
        // repairs focus; the dragged Pane object lives on in the new tab.
        #expect(tab.splitRoot.allPanes().map(\.id) == [original])
        #expect(tab.zoomedPaneID == nil)
        #expect(tab.focusedPaneID == original)
        #expect(ws.tabs.count == 2)
        let newTab = try #require(ws.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(newTab.focusedPaneID == dragged)
        #expect(ws.activeTabID == newTab.id)
    }

    @Test
    func separatePane_at_index_lands_at_that_slot() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let dragged = try #require(tab.focusedPaneID)

        state.separatePane(dragged, toProject: p.id, destPath: p.path, at: 0)

        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.first?.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(ws.tabs.last?.id == tab.id)
    }

    @Test
    func separatePane_across_projects_rebinds_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        state.selectProject(p1)
        state.splitPane(direction: .horizontal, projectID: p1.id)
        let sourceTab = try #require(ws1.activeTab)
        let dragged = try #require(sourceTab.focusedPaneID)
        let ws2TabsBefore = ws2.tabs.count

        state.separatePane(dragged, toProject: p2.id, destPath: p2.path)

        #expect(sourceTab.splitRoot.allPanes().count == 1)
        #expect(ws2.tabs.count == ws2TabsBefore + 1)
        let newTab = try #require(ws2.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        // Routing identity follows the pane, mirroring moveTab's rebind.
        #expect(newTab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == newTab.id)
    }

    @Test
    func separatePane_only_pane_of_its_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let onlyPane = try #require(tab.focusedPaneID)
        state.separatePane(onlyPane, toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().map(\.id) == [onlyPane])
    }

    @Test
    func separatePane_unknown_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        state.separatePane(UUID(), toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Project-scoped tab navigation

    @Test
    func selectNextTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let other = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ws.createTab(projectPath: p.path).id
        // Seed a tab in the sibling project so a leak across projects would show.
        _ = try #require(state.workspaces[other.id]?.activeTabID)
        state.activeProjectID = p.id
        ws.selectTab(first)

        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        // At the last tab it wraps to the first rather than crossing over.
        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectPreviousTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        _ = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ws.createTab(projectPath: p.path).id
        state.activeProjectID = p.id
        ws.selectTab(first)

        // At the first tab it wraps to the last rather than crossing over.
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectNextTab_single_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let only = try #require(ws.activeTabID)
        state.selectNextTab(projectID: p.id)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == only)
    }

    // MARK: - Focus navigation

    @Test
    func focusPaneInDirection_right_in_horizontal_split() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func focusPaneInDirection_no_neighbor_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    @Test
    func cyclePane_forward_advances_in_tree_order() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["c"])
    }

    @Test
    func cyclePane_forward_wraps_at_end() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["b"]
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["a"])
    }

    @Test
    func cyclePane_backward_wraps_at_start() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.cyclePane(forward: false, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func cyclePane_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    // MARK: - Project lifecycle

    @Test
    func removeProject_drops_workspace_and_clears_active_when_matching() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)
        state.removeProject(p.id)
        #expect(state.workspaces[p.id] == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func removeProject_leaves_active_alone_when_not_matching() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // p2 is active; remove p1.
        state.removeProject(p1.id)
        #expect(state.activeProjectID == p2.id)
    }

    @Test
    func two_projects_for_the_same_directory_get_independent_workspaces_and_sessions() throws {
        // Removing the one-project-per-directory constraint: distinct projects
        // may share a path yet keep wholly separate workspaces (keyed on
        // Project.id) and non-colliding zmx sessions (per-pane hex entropy).
        let state = makeAppState()
        let a = seedProject(state, name: "a", path: "/tmp/shared")
        let b = seedProject(state, name: "b", path: "/tmp/shared")

        #expect(a.id != b.id)
        let wsA = try #require(state.workspaces[a.id])
        let wsB = try #require(state.workspaces[b.id])
        #expect(wsA !== wsB)

        // Session names differ despite the shared path: the slug matches but
        // each pane's hex suffix comes from its own UUID.
        let nameA = try #require(wsA.activeTab?.splitRoot.allPanes().first?.sessionName)
        let nameB = try #require(wsB.activeTab?.splitRoot.allPanes().first?.sessionName)
        #expect(nameA != nameB)
    }

    // MARK: - Bulk removal (sidebar multi-select)

    @Test
    func removeProjects_drops_every_listed_workspace() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let p3 = seedProject(state, name: "p3", path: "/tmp3")

        state.removeProjects([p1.id, p3.id])

        #expect(state.workspaces[p1.id] == nil)
        #expect(state.workspaces[p3.id] == nil)
        #expect(state.workspaces[p2.id] != nil)
    }

    @Test
    func removeProjects_empty_list_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.removeProjects([])
        #expect(state.workspaces[p.id] != nil)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func closeTabs_closes_each_tab_across_projects() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        // Two tabs in each so closing one doesn't empty the workspace.
        let close1 = ws1.createTab(projectPath: "/tmp1")
        let keep1 = try #require(ws1.tabs.first?.id)
        let close2 = ws2.createTab(projectPath: "/tmp2")
        let keep2 = try #require(ws2.tabs.first?.id)

        state.closeTabs([
            (tabID: close1.id, projectID: p1.id),
            (tabID: close2.id, projectID: p2.id),
        ])

        #expect(ws1.tabs.map(\.id) == [keep1])
        #expect(ws2.tabs.map(\.id) == [keep2])
    }

    @Test
    func requestRemoveSelection_runs_removal_immediately_when_no_pane_busy() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // No pane ever gets an NSView in tests, so nothing is "busy" — the
        // removal must run inline rather than staging a confirmation.
        var ran = false
        state.requestRemoveSelection(projectIDs: [p1.id, p2.id], tabs: []) { ran = true }

        #expect(ran)
        #expect(state.pendingBulkRemove == nil)
    }

    @Test
    func pendingBulkRemove_confirm_and_cancel() {
        let state = makeAppState()

        // Stage manually (busy detection needs a live surface).
        var ran = false
        state.pendingBulkRemove = AppState.PendingBulkRemove { ran = true }
        state.cancelPendingBulkRemove()
        #expect(state.pendingBulkRemove == nil)
        #expect(!ran)

        state.pendingBulkRemove = AppState.PendingBulkRemove { ran = true }
        state.confirmPendingBulkRemove()
        #expect(state.pendingBulkRemove == nil)
        #expect(ran)
    }

    @Test
    func selectTab_persists_cleared_completion_indicator() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)
        let state = makeAppState(store: store)
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        pane.executionState = .done
        state.saveWorkspaces()

        state.selectTab(tab.id, projectID: project.id)

        let restored = WorkspaceSerializer.restore(from: store.load().workspaces, validIDs: [project.id])
        #expect(restored.first?.tabs.first?.executionState == .idle)
    }

    @Test
    func selectProject_persists_cleared_active_tab_indicator() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)
        let state = makeAppState(store: store)
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        _ = seedProject(state, name: "p2", path: "/tmp2")
        let tab = try #require(state.workspaces[p1.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        pane.executionState = .done
        state.saveWorkspaces()

        state.selectProject(p1)

        let restored = WorkspaceSerializer.restore(from: store.load().workspaces, validIDs: [p1.id])
        #expect(restored.first?.tabs.first?.executionState == .idle)
    }

    // MARK: - Unload project

    @Test
    func unloadProject_keeps_tab_structure_with_fresh_panes() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        state.splitPane(direction: .horizontal, projectID: p.id)
        ws.createTab(projectPath: "/tmp")
        ws.tabs[1].customTitle = "build"
        let beforePaneIDs = Set(ws.tabs.flatMap { $0.splitRoot.allPanes().map(\.id) })
        let beforeTabIDs = ws.tabs.map(\.id)

        state.unloadProject(p.id)

        let after = try #require(state.workspaces[p.id])
        #expect(after.tabs.map(\.id) == beforeTabIDs)
        #expect(after.tabs[0].splitRoot.allPanes().count == 2)
        #expect(after.tabs[1].customTitle == "build")
        // Panes are rebuilt fresh (no surfaces), like a launch restore.
        let afterPaneIDs = Set(after.tabs.flatMap { $0.splitRoot.allPanes().map(\.id) })
        #expect(afterPaneIDs.isDisjoint(with: beforePaneIDs))
    }

    @Test
    func unloadProject_destroys_pane_views() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        _ = pane.ensureNSView()
        #expect(state.isProjectLoaded(p.id))

        state.unloadProject(p.id)

        #expect(pane.nsView == nil)
        #expect(!state.isProjectLoaded(p.id))
    }

    @Test
    func unloadProject_active_project_is_deselected_but_kept() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)
        state.unloadProject(p.id)
        #expect(state.activeProjectID == nil)
        #expect(state.workspaces[p.id] != nil)
    }

    @Test
    func unloadProject_other_project_keeps_active() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        state.unloadProject(p1.id)
        #expect(state.activeProjectID == p2.id)
        #expect(state.workspaces[p1.id] != nil)
    }

    @Test
    func unloadProject_unknown_project_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(UUID())
        #expect(state.activeProjectID == p.id)
        #expect(state.workspaces.count == 1)
    }

    @Test
    func unloadProject_marks_the_project_unloaded() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(!state.isProjectUnloaded(p.id))
        state.unloadProject(p.id)
        // The sidebar reads this to dim the project's tab rows, the same way
        // a closed pinned tab's row is dimmed.
        #expect(state.isProjectUnloaded(p.id))
    }

    @Test
    func selecting_an_unloaded_project_clears_the_mark() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(p.id)
        state.selectProject(p)
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func becoming_active_clears_the_mark_without_selectProject() {
        let state = makeAppState()
        let p = seedProject(state, name: "p1", path: "/tmp1")
        _ = seedProject(state, name: "p2", path: "/tmp2")
        state.unloadProject(p.id)
        // Every load path makes the project active — a cross-project tab
        // move or a global tab cycle sets the id directly.
        state.activeProjectID = p.id
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func removing_an_unloaded_project_forgets_the_mark() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(p.id)
        state.removeProject(p.id)
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func isProjectLoaded_false_without_views_or_workspace() {
        let state = makeAppState()
        #expect(!state.isProjectLoaded(UUID()))
        let p = seedProject(state)
        // Workspace exists but no pane has a view yet (nothing ever rendered).
        #expect(!state.isProjectLoaded(p.id))
    }

    // MARK: - Rename state

    @Test
    func renamingTabID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renamingTabID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingTabID = id
        #expect(state.renamingTabID == id)
        state.renamingTabID = nil
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renameTabContaining_targets_the_panes_tab() async throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)
        state.sidebarVisible = false

        state.renameTab(containing: paneID, projectID: p.id)

        #expect(state.sidebarVisible)
        // The rename target lands a runloop tick later (the sidebar row's
        // TextField must exist before it's asked to edit) — poll with sleeps.
        for _ in 0 ..< 100 where state.renamingTabID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.renamingTabID == tab.id)
    }

    @Test
    func renameTabContaining_unknown_pane_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.sidebarVisible = false
        state.renameTab(containing: UUID(), projectID: p.id)
        #expect(!state.sidebarVisible)
    }

    @Test
    func setTabTitleContaining_sets_and_clears_customTitle() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        state.setTabTitle(containing: paneID, projectID: p.id, title: "deploy")
        #expect(tab.customTitle == "deploy")

        // Empty/nil restores the automatic title, same contract as the
        // ghostty keybind.
        state.setTabTitle(containing: paneID, projectID: p.id, title: nil)
        #expect(tab.customTitle == nil)
    }

    @Test
    func renamingProjectID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingProjectID == nil)
    }

    @Test
    func renamingProjectID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingProjectID = id
        #expect(state.renamingProjectID == id)
        state.renamingProjectID = nil
        #expect(state.renamingProjectID == nil)
    }

    @Test
    func postPaletteAction_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.postPaletteAction == nil)
    }

    @Test
    func postPaletteAction_is_invoked_and_consumed() {
        let state = makeAppState()
        var invoked = false
        state.postPaletteAction = { invoked = true }
        #expect(state.postPaletteAction != nil)
        state.postPaletteAction?()
        state.postPaletteAction = nil
        #expect(invoked)
        #expect(state.postPaletteAction == nil)
    }

    // MARK: - requestClosePane / pendingClosePane

    @Test
    func requestClosePane_without_running_process_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        // No GhosttyTerminalNSView is ever created in tests, so needsConfirmQuit is false.
        state.requestClosePane(target, projectID: p.id)
        #expect(state.pendingClosePane == nil)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - applyLayout

    /// Create a temp project directory and seed a workspace rooted there.
    private func seedProjectWithDir(_ state: AppState) -> (project: Project, root: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Project(name: "proj", path: dir.path, sortOrder: 0)
        state.selectProject(p)
        return (p, dir.path)
    }

    /// Write a raw central project file into `store`'s directory.
    private func writeProjectFile(_ yaml: String, in store: ProjectFileStore, filename: String = "test.yaml") {
        try? FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try? yaml.write(to: store.directoryURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    @Test
    func selecting_project_with_matching_project_file_auto_applies_on_first_open() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-autoapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A central file declaring this path exists *before* first open.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let project = Project(name: "auto", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Workspace built from the file (one tab, two panes), not the default
        // single-pane workspace. Non-destructive on first open → no prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        #expect(state.pendingLayoutApply == nil)
        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func first_open_without_a_project_file_uses_the_default_workspace() throws {
        // No central file declares this path, so first open is a plain
        // single-pane workspace — nothing to seed it from now that the
        // in-repo `.macterm/layout.yaml` path is gone.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-nofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "No File", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingLayoutError == nil)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
        // Nothing is written on open — files appear only on explicit Save Layout.
        #expect(files.find(forProjectPath: dir.path) == nil)
    }

    @Test
    func first_open_with_invalid_project_file_surfaces_error_and_uses_default_workspace() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Header identifies the file; tabs fail the full decode.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - split: { direction: horizontal, first: {} }
        """, in: files)

        let project = Project(name: "broken", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingLayoutError?.verb == "apply")
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    @Test
    func apply_layout_without_a_project_file_surfaces_an_error() throws {
        // An already-open project with no central declaration: Apply Layout has
        // nothing to read and says so, rather than silently doing nothing.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-applynofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "Existing", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingLayoutError?.verb == "apply")
        #expect(files.find(forProjectPath: dir.path) == nil)
        // The live workspace is untouched by a failed apply.
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    // MARK: - Action toasts

    @Test
    func save_layout_toasts_with_the_full_path_it_wrote() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, _) = seedProjectWithDir(state) // name "proj" → proj.yaml

        state.saveLayoutPresentingError(project)

        #expect(state.pendingLayoutError == nil)
        #expect(state.activeToast?.title == "Layout saved")
        // The full path, not just the filename: the projects directory isn't
        // somewhere the user necessarily has in mind, so the subtitle has to
        // say where to go look — while still naming *which* file a save with
        // several same-path candidates landed in.
        let subtitle = try #require(state.activeToast?.subtitle)
        #expect(subtitle.hasSuffix("proj.yaml"))
        #expect(subtitle.contains("/"))
        #expect(subtitle == ProjectPath.homeContracted(files.directoryURL.appendingPathComponent("proj.yaml").path))
    }

    @Test
    func save_layout_toast_contracts_the_home_prefix() {
        // A path under home renders as `~/…` — readable, and it keeps the
        // username out of screenshots. `homeContracted` is the same helper the
        // written file's own `path:` uses, so the two can't drift.
        let home = ProjectPath.currentHome
        #expect(ProjectPath.homeContracted("\(home)/.config/macterm/projects/a.yaml")
            == "~/.config/macterm/projects/a.yaml")
        // Outside home, it passes through rather than mangling the path.
        #expect(ProjectPath.homeContracted("/etc/macterm/a.yaml") == "/etc/macterm/a.yaml")
    }

    @Test
    func save_layout_conflict_raises_a_dialog_instead_of_a_toast() {
        // A stray file declaring the same path makes the save a *notice*, not a
        // clean success. Toasting "Layout saved" alongside would undercut the
        // dialog that explains what's wrong.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // Bare `path:` with no `name:` — files no project's slug owns, which is
        // what makes them strays rather than a sibling's legitimate file. Two,
        // mirroring `save_layout_lists_ignored_duplicates_when_the_save_wins`:
        // the save claims one and reports the rest.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        #expect(state.pendingLayoutError != nil)
        #expect(state.activeToast == nil)
    }

    @Test
    func apply_layout_toasts_only_when_user_invoked() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-toastapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "toast", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // The first-open seed fires unbidden — it must stay silent.
        #expect(state.activeToast == nil)

        state.applyLayoutPresentingError(project, confirming: true)

        #expect(state.pendingLayoutError == nil)
        #expect(state.activeToast?.title == "Layout applied")
    }

    /// Both scenes in `MactermApp` bind alerts to this one pending value, so a
    /// staged dialog has to say which window asked for it — an ungated binding
    /// opens the settings window purely to stack a duplicate dialog on the one
    /// the user is answering. The default must stay the main window: everything
    /// but the settings pane (palette, menu, sidebar, CLI) relies on it.
    @Test
    func staged_destructive_apply_records_the_window_that_asked_for_it() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-applyhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "applyhost", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        // A second live tab the one-tab declaration doesn't mention: applying
        // would close it, which is what stages the confirmation.
        state.createTab(projectID: project.id, projectPath: dir.path)

        state.applyLayoutPresentingError(project, confirming: true)
        #expect(state.pendingLayoutApply?.host == .mainWindow)

        state.cancelPendingLayoutApply()

        state.applyLayoutPresentingError(project, confirming: true, host: .settings)
        #expect(state.pendingLayoutApply?.host == .settings)
    }

    /// Same gate for the notice alerts: a Settings-invoked failure must not
    /// surface behind the main window (or in both).
    @Test
    func layout_error_records_the_window_that_asked_for_it() {
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project, confirming: true)
        #expect(state.pendingLayoutError?.host == .mainWindow)

        state.pendingLayoutError = nil

        state.applyLayoutPresentingError(project, confirming: true, host: .settings)
        #expect(state.pendingLayoutError?.host == .settings)
    }

    @Test
    func apply_layout_failure_raises_a_dialog_instead_of_a_toast() {
        // No file declares this project's path — the command surfaces the
        // error, and a success toast would flatly contradict it.
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project, confirming: true)

        #expect(state.pendingLayoutError != nil)
        #expect(state.activeToast == nil)
    }

    @Test
    func dismissing_a_superseded_toast_leaves_the_newer_one_up() {
        // The auto-dismiss task is keyed by toast id. A stale one firing after
        // a second toast replaced the first must not cut the new one short.
        let state = makeAppState()
        state.presentToast("First")
        let first = try? #require(state.activeToast?.id)
        state.presentToast("Second")

        if let first { state.dismissToast(first) }

        #expect(state.activeToast?.title == "Second")
    }

    @Test
    func dismissing_the_current_toast_clears_it() {
        let state = makeAppState()
        state.presentToast("Only")
        let id = state.activeToast?.id

        if let id { state.dismissToast(id) }

        #expect(state.activeToast == nil)
    }

    @Test
    func a_subtitled_toast_stays_up_longer() {
        // Two lines need more reading time than one.
        #expect(Toast(title: "Bare").duration < Toast(title: "Detailed", subtitle: "more").duration)
    }

    // MARK: - saveLayout duplicate conflicts

    @Test
    func save_layout_does_not_flag_a_sibling_projects_file() {
        // A distinct-name sibling on the same directory owns its own file.
        // Saving this project must neither report that file as a stray nor
        // realign-delete it.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state) // name "proj" → proj.yaml
        let sibling = Project(name: "other", path: root, sortOrder: 1)
        writeProjectFile("name: other\npath: \(root)", in: files, filename: "other.yaml")

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingLayoutError == nil)
        #expect(files.find(forProjectPath: root, preferredSlug: "other")?.url.lastPathComponent == "other.yaml")
        #expect(files.find(forProjectPath: root, preferredSlug: "proj")?.url.lastPathComponent == "proj.yaml")
    }

    @Test
    func save_layout_lists_ignored_duplicates_when_the_save_wins() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // "proj.yaml" (the save target) sorts before the surviving duplicate.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        let notice = try #require(state.pendingLayoutError)
        #expect(notice.title == "Layout saved with a conflict")
        #expect(notice.message.contains("zzz.yaml"))
        #expect(notice.message.contains("ignored"))
    }

    @Test
    func save_layout_stays_silent_without_duplicates() {
        let state = makeAppState()
        let (project, _) = seedProjectWithDir(state)
        state.saveLayoutPresentingError(project)
        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func save_layout_warns_when_a_same_named_project_shares_the_directory() throws {
        // Two projects for one directory with the same name → same filename
        // slug → the same layout file. The save silently overwrote the other's
        // layout, so it must warn.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "proj", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        let notice = try #require(state.pendingLayoutError)
        #expect(notice.title == "Layout file shared with another project")
        #expect(notice.message.contains("proj"))
    }

    @Test
    func save_layout_stays_silent_when_same_dir_projects_have_distinct_names() {
        // Same directory but different names → distinct slug files
        // (`proj.yaml` / `other.yaml`), so there's no shared-file overwrite.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "other", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func each_same_directory_project_saves_and_loads_its_own_layout() throws {
        // The core guarantee of per-project layout identity: two distinct-name
        // projects on one directory each save to and load from their own file —
        // saving one never clobbers the other's, and neither resolves the
        // other's on load (path alone can't tell them apart; the slug does).
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let alpha = Project(name: "alpha", path: dir.path, sortOrder: 0)
        let bravo = Project(name: "bravo", path: dir.path, sortOrder: 1)
        state.selectProject(alpha)
        state.selectProject(bravo)
        let siblings = [alpha, bravo]

        state.saveLayoutPresentingError(alpha, siblingProjects: siblings)
        state.saveLayoutPresentingError(bravo, siblingProjects: siblings)

        #expect(state.pendingLayoutError == nil)
        // Both files coexist — saving bravo didn't realign-delete alpha's.
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "alpha")?.url.lastPathComponent == "alpha.yaml")
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "bravo")?.url.lastPathComponent == "bravo.yaml")
        // Each resolves the file it wrote, identified by the stored name.
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "alpha")?.name == "alpha")
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "bravo")?.name == "bravo")
    }

    @Test
    func selecting_project_without_layout_file_uses_default_workspace() {
        let state = makeAppState()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-nolayout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "plain", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // No layout file → default single-pane workspace.
        #expect(state.workspaces[project.id]?.tabs.count == 1)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    @Test
    func reopen_restores_snapshot_silently_and_ignores_project_file() throws {
        // Reopen is always silent: a restored session snapshot wins (a
        // project's panes must reattach their live zmx sessions, and its live
        // layout is remembered), and the declared file is NOT applied and NOT
        // prompted for — even when it differs. The file only seeds a genuine
        // first open (no snapshot), covered by the next test.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "winner", path: dir.path, sortOrder: 0)

        // Pre-seed a saved snapshot for the project: a single-pane workspace.
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: storeURL)
        let snapshotWS = Workspace(projectID: project.id, projectPath: dir.path)
        store.save(WorkspaceSerializer.snapshot([project.id: snapshotWS]))

        // And a central file declaring a different (two-pane) split.
        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        // Restored snapshot wins: one pane, file NOT applied, NO prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs[0].splitRoot.allPanes().count == 1)
        #expect(ws.tabs[0].customTitle != "Dev")
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func project_file_auto_applies_on_genuine_first_open_without_snapshot() throws {
        // No snapshot at all → the declared file still seeds the workspace on
        // first open (pure-spawn, no prompt). The only auto-apply path left.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-firstopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "fresh", path: dir.path, sortOrder: 0)
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_malformed_file_returns_error_and_does_not_apply() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        // Invalid: a `split` mapping missing its `second` child.
        writeProjectFile("path: \(root)\ntabs:\n  - split: { direction: horizontal, first: {} }\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        // Workspace is untouched — same tabs, nothing spawned or closed.
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_missing_file_returns_error_and_does_not_apply() throws {
        let state = makeAppState()
        let (p, _) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_empty_tabs_returns_error_and_never_plans_destruction() throws {
        // A bare declaration (no tabs:) must read as "nothing to apply" —
        // planning against an empty tab list would close every live tab.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        writeProjectFile("name: bare\npath: \(root)\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_name_mismatch_applies_without_prompt() {
        // Files are matched by path; a differing `name:` is expected drift
        // (project renamed since last save), never a confirmation.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state) // project name "proj"

        writeProjectFile("name: OtherApp\npath: \(root)\ntabs:\n  - {}\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error == nil)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func saveLayout_creates_central_file_declaring_the_project_path() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)

        let error = state.saveLayout(project: p)

        #expect(error == nil)
        let saved = try #require(try files.loadFull(forProjectPath: root))
        #expect(saved.name == "proj")
        #expect(saved.path == root)
        #expect(saved.tabs?.count == 1)
        #expect(files.find(forProjectPath: root)?.url.lastPathComponent == "proj.yaml")
    }

    // MARK: - panesToWarm (eager process start for focused project)

    @Test
    func panesToWarm_excludes_active_tab_includes_the_rest() {
        let pid = UUID()
        // Tab A (active): 1 pane. Tab B: 2-pane split. Tab C: 1 pane.
        let a = Pane(projectPath: "/p", projectID: pid)
        let (bTree, bIDs) = build(H(pane("b1"), pane("b2")))
        let c = Pane(projectPath: "/p", projectID: pid)
        let tabA = TerminalTab(id: UUID(), splitRoot: .pane(a), focusedPaneID: a.id)
        let tabB = TerminalTab(id: UUID(), splitRoot: bTree, focusedPaneID: nil)
        let tabC = TerminalTab(id: UUID(), splitRoot: .pane(c), focusedPaneID: c.id)
        let ws = Workspace(projectID: pid, tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        let warm = Set(AppState.panesToWarm(in: ws).map(\.id))
        // Active tab A's pane is NOT warmed (SwiftUI starts it); B's two + C are.
        #expect(!warm.contains(a.id))
        #expect(warm == Set([bIDs["b1"], bIDs["b2"], c.id].compactMap(\.self)))
        #expect(warm.count == 3)
    }

    @Test
    func panesToWarm_single_tab_workspace_warms_nothing() {
        let pid = UUID()
        let only = Pane(projectPath: "/p", projectID: pid)
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(only), focusedPaneID: only.id)
        let ws = Workspace(projectID: pid, tabs: [tab], activeTabID: tab.id)
        #expect(AppState.panesToWarm(in: ws).isEmpty)
    }

    @Test
    func panesToWarmAtLaunch_warms_all_background_panes_but_skips_the_visible_tab() {
        let activeID = UUID()
        let backgroundID = UUID()
        let missingID = UUID()

        let visible = Pane(projectPath: "/active", projectID: activeID)
        let hidden = Pane(projectPath: "/active", projectID: activeID)
        let activeTab = TerminalTab(id: UUID(), splitRoot: .pane(visible), focusedPaneID: visible.id)
        let hiddenTab = TerminalTab(id: UUID(), splitRoot: .pane(hidden), focusedPaneID: hidden.id)
        let activeWorkspace = Workspace(
            projectID: activeID,
            tabs: [activeTab, hiddenTab],
            activeTabID: activeTab.id
        )

        let backgroundOne = Pane(projectPath: "/background", projectID: backgroundID)
        let backgroundTwo = Pane(projectPath: "/background", projectID: backgroundID)
        let backgroundTree = SplitNode.split(SplitBranch(
            direction: .horizontal,
            ratio: 0.5,
            first: .pane(backgroundOne),
            second: .pane(backgroundTwo)
        ))
        let backgroundTab = TerminalTab(id: UUID(), splitRoot: backgroundTree, focusedPaneID: backgroundOne.id)
        let backgroundWorkspace = Workspace(
            projectID: backgroundID,
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )

        let warm = AppState.panesToWarmAtLaunch(
            projectIDs: [activeID, missingID, backgroundID],
            workspaces: [activeID: activeWorkspace, backgroundID: backgroundWorkspace],
            activeProjectID: activeID
        )

        #expect(warm.map(\.id) == [hidden.id, backgroundOne.id, backgroundTwo.id])
    }

    @Test
    func panesToWarmAtLaunch_warms_every_pane_when_pinned_tabs_are_active() {
        let projectID = UUID()
        let pane = Pane(projectPath: "/background", projectID: projectID)
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        let workspace = Workspace(projectID: projectID, tabs: [tab], activeTabID: tab.id)

        let warm = AppState.panesToWarmAtLaunch(
            projectIDs: [projectID],
            workspaces: [projectID: workspace],
            activeProjectID: PinnedTabs.projectID
        )

        #expect(warm.map(\.id) == [pane.id])
    }

    @Test
    func launchWarmSchedule_paces_each_remote_destination_without_slowing_local_panes() {
        let projectID = UUID()
        let localOne = Pane(projectPath: "/local", projectID: projectID)
        let remoteOne = Pane(projectPath: "example:~/one", projectID: projectID)
        let otherRemoteOne = Pane(projectPath: "other:~/one", projectID: projectID)
        let remoteTwo = Pane(projectPath: "example:~/two", projectID: projectID)
        let localTwo = Pane(projectPath: "/local", projectID: projectID)
        let otherRemoteTwo = Pane(projectPath: "other:~/two", projectID: projectID)

        let schedule = AppState.launchWarmSchedule(
            [localOne, remoteOne, otherRemoteOne, remoteTwo, localTwo, otherRemoteTwo],
            // The visible tab is already starting a connection to example.
            alreadyStartingRemoteDestinations: ["example"]
        )

        #expect(schedule.map(\.pane.id) == [
            localOne.id,
            remoteOne.id,
            otherRemoteOne.id,
            remoteTwo.id,
            localTwo.id,
            otherRemoteTwo.id,
        ])
        #expect(schedule.map(\.delay) == [0, 1, 0.25, 2, 0.5, 1.25])
    }

    @Test
    func launchWarmSchedule_starts_the_first_background_remote_destination_immediately() {
        let projectID = UUID()
        let first = Pane(projectPath: "example:~/one", projectID: projectID)
        let second = Pane(projectPath: "example:~/two", projectID: projectID)

        let schedule = AppState.launchWarmSchedule([first, second])

        #expect(schedule.map(\.delay) == [0, 1])
    }

    @Test
    func warmRestoredProjects_stamps_remote_zmx_path_before_warming() {
        let state = makeAppState()
        let project = Project(
            name: "remote",
            path: "example:~/work",
            zmxPath: "/custom/bin/zmx"
        )
        let pane = Pane(projectPath: project.path, projectID: project.id)
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        state.workspaces[project.id] = Workspace(
            projectID: project.id,
            tabs: [tab],
            activeTabID: tab.id
        )

        var warmed: [UUID] = []
        state.warmPane = { warmedPane in
            #expect(warmedPane.remoteZmxPath == "/custom/bin/zmx")
            warmed.append(warmedPane.id)
        }

        state.warmRestoredProjects([project])

        #expect(warmed == [pane.id])
        #expect(state.activeProjectID == nil)
    }

    @Test
    func warmRestoredProjects_warms_local_background_projects() {
        let state = makeAppState()
        let activeProject = Project(name: "active", path: "/tmp/active", sortOrder: 0)
        let backgroundProject = Project(name: "background", path: "/tmp/background", sortOrder: 1)

        let activePane = Pane(projectPath: activeProject.path, projectID: activeProject.id)
        let activeTab = TerminalTab(
            id: UUID(),
            splitRoot: .pane(activePane),
            focusedPaneID: activePane.id
        )
        state.workspaces[activeProject.id] = Workspace(
            projectID: activeProject.id,
            tabs: [activeTab],
            activeTabID: activeTab.id
        )

        let backgroundPane = Pane(projectPath: backgroundProject.path, projectID: backgroundProject.id)
        let backgroundTab = TerminalTab(
            id: UUID(),
            splitRoot: .pane(backgroundPane),
            focusedPaneID: backgroundPane.id
        )
        state.workspaces[backgroundProject.id] = Workspace(
            projectID: backgroundProject.id,
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        state.activeProjectID = activeProject.id

        var warmed: [UUID] = []
        state.warmPane = { warmed.append($0.id) }

        state.warmRestoredProjects([activeProject, backgroundProject])

        #expect(warmed == [backgroundPane.id])
        #expect(backgroundPane.remoteZmxPath == nil)
    }

    // MARK: - Quiet-settle

    // The poll calls `pane.settleTerminalActivityIfQuiet()` directly (no
    // occlusion special-casing): the OUTPUT_ACTIVITY heartbeat that sources
    // activity is occlusion-independent, so a quiet pane settles the same
    // whether or not it is on screen. These drive the settle in isolation —
    // deterministic (no live surface, no `Preferences` global) and a truer
    // unit than the full `refreshAllForegroundProcesses` tick, which re-reads
    // each pane's real foreground process (nil under test, clearing the run
    // source).

    /// A pane whose activity went quiet long ago (past the 3s settle window).
    private func quietRunningPane() -> Pane {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        pane.recordUserInteraction()
        pane.markTerminalActivity(at: Date().addingTimeInterval(-10))
        #expect(pane.executionState == .running)
        return pane
    }

    @Test
    func quiet_activity_run_settles_to_done() {
        let pane = quietRunningPane()
        // 10s of silence is past the window — occluded or not, it's done.
        pane.settleTerminalActivityIfQuiet()
        #expect(pane.executionState == .done)
    }

    @Test
    func activity_run_holds_until_the_quiet_window_elapses() {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        pane.recordUserInteraction()
        let start = Date()
        pane.markTerminalActivity(at: start)
        pane.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3)
        #expect(pane.executionState == .running)
        pane.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(pane.executionState == .done)
    }

    // MARK: - zmx session lifecycle on close paths

    /// A ZmxClient that records every killed session name. Remote kills are
    /// recorded into `remoteKilled` (when given) so a test can assert routing.
    private func recordingZmx(
        into killed: KilledSessions,
        remoteInto remoteKilled: KilledSessions? = nil
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, name, _ in await (remoteKilled ?? killed).append(name) },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func closeTab_kills_every_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let names = Set(tab.splitRoot.allPanes().map(\.sessionName))
        #expect(names.count == 2)

        // Second tab so the close leaves a valid workspace.
        _ = state.workspaces[p.id]?.createTab(projectPath: "/tmp")
        state.closeTab(tab.id, projectID: p.id)

        await killed.settle(expecting: names.count)
        #expect(await killed.names == names)
    }

    @Test
    func closing_remote_pane_routes_kill_over_ssh() async throws {
        // A remote pane's session lives on the remote daemon — a local kill
        // of its name would silently no-op and strand the session (#104).
        let killed = KilledSessions()
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed, remoteInto: remoteKilled)
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await remoteKilled.settle(expecting: 1)
        #expect(await remoteKilled.names == [targetName])
        #expect(await killed.names.isEmpty)
    }

    // MARK: - Process-exit routing (#281)

    /// A ZmxClient whose orphan-sweep probe answers with a fixed listing (the
    /// process-exit liveness probe) and records remote kills.
    private func probeAnsweringZmx(
        entries: [ZmxSessionListParser.Entry]?,
        remoteKilled: KilledSessions
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, name, _ in await remoteKilled.append(name) },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in entries },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func process_exit_closes_a_local_pane() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let target = try #require(tab.focusedPaneID)
        let name = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.handleProcessExit(target, projectID: p.id)

        #expect(tab.splitRoot.findPane(id: target) == nil)
        await killed.settle(expecting: 1)
        #expect(await killed.names.contains(name))
    }

    @Test
    func remote_process_exit_keeps_the_pane_while_its_session_lives() async throws {
        // The drop case (#281): the ssh client died but the host still has
        // the session — the pane must survive for the reconnect sweep, and
        // nothing may kill the session.
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(
            entries: [.init(name: pane.sessionName, clients: 0, owner: "us")],
            remoteKilled: remoteKilled
        )

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
        #expect(await remoteKilled.names.isEmpty)
    }

    @Test
    func remote_process_exit_keeps_the_pane_when_the_host_is_unreachable() async throws {
        // Fail-safe: no answer must never destroy the pane (wrongly keeping
        // one costs a manual close; wrongly closing one costs the session).
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(entries: nil, remoteKilled: remoteKilled)

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
        #expect(await remoteKilled.names.isEmpty)
    }

    @Test
    func remote_process_exit_closes_the_pane_when_the_session_is_gone() async throws {
        // The deliberate end (typed `exit` killed the session): the host
        // positively reports it gone, so the pane closes as it always did.
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        // A second tab so the close leaves a valid workspace shape.
        _ = state.workspaces[p.id]?.createTab(projectPath: "devbox:~/dev/api")
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(entries: [], remoteKilled: remoteKilled)

        state.handleProcessExit(pane.id, projectID: p.id)

        // The close happens after the async probe answers.
        await remoteKilled.settle(expecting: 1)
        #expect(state.workspaces[p.id]?.tabs.allSatisfy { $0.splitRoot.findPane(id: pane.id) == nil } == true)
    }

    @Test
    func remote_process_exit_keeps_the_pane_when_probes_are_disabled() async throws {
        // backgroundSSHConnections off (#272): no probe is allowed, so every
        // remote exit conservatively keeps the pane.
        let prior = Preferences.shared.backgroundSSHConnections
        defer { Preferences.shared.backgroundSSHConnections = prior }
        Preferences.shared.backgroundSSHConnections = false
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(
            entries: [],
            remoteKilled: remoteKilled
        )

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
    }

    // MARK: - Background ssh connections toggle (#272)

    /// A ZmxClient whose foreground probe records each invocation. The kill
    /// paths are irrelevant here; only the probe seam matters.
    private func probeCountingZmx(into probes: KilledSessions) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in
                await probes.append(UUID().uuidString)
                return .unreachable
            },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func background_ssh_toggle_gates_every_remote_probe() async throws {
        let prior = Preferences.shared.backgroundSSHConnections
        defer { Preferences.shared.backgroundSSHConnections = prior }
        let probes = KilledSessions()
        let state = makeAppState()
        state.zmx = probeCountingZmx(into: probes)
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        // Primed at init — the request that would bypass the resolver's
        // per-host interval AND the window-visibility filter, so this test
        // needs neither a visible window nor a 3s wait.
        #expect(pane.remoteProbePending)

        Preferences.shared.backgroundSSHConnections = false
        state.refreshAllForegroundProcesses()
        // The resolver consumes a pending request synchronously the moment it
        // fires the host's probe, so a still-pending request proves the tick
        // never reached the resolver — deterministic, no negative-wait.
        #expect(pane.remoteProbePending)
        #expect(await probes.names.isEmpty)

        Preferences.shared.backgroundSSHConnections = true
        state.refreshAllForegroundProcesses()
        #expect(!pane.remoteProbePending)
        await probes.settle(expecting: 1)
        #expect(await probes.names.count == 1)
    }

    @Test
    func closePane_kills_only_that_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await killed.settle(expecting: 1)
        #expect(await killed.names == [targetName])
    }

    @Test
    func unloadProject_kills_every_session_but_keeps_layout() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let names = try Set(
            #require(state.workspaces[p.id]).tabs
                .flatMap { $0.splitRoot.allPanes() }
                .map(\.sessionName)
        )
        #expect(names.count == 2)

        state.unloadProject(p.id)

        await killed.settle(expecting: names.count)
        // Sessions die (unload = stop the project's shells)…
        #expect(await killed.names == names)
        // …but the layout survives for the next open.
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
    }

    @Test
    func moveTab_kills_nothing() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let moving = try #require(state.workspaces[p1.id]?.tabs.first?.id)

        state.moveTab(moving, from: p1.id, to: p2.id, destPath: p2.path)

        await killed.settleExpectingNone()
        #expect(await killed.names.isEmpty)
    }

    @Test
    func moveTab_restamps_pane_routing_identity_but_not_session() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let tab = try #require(state.workspaces[p1.id]?.activeTab)
        // Split so the moved tab carries more than one pane to restamp.
        state.splitPane(direction: .horizontal, projectID: p1.id)
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let originalSessionNames = Set(panes.map(\.sessionName))
        let originalPaths = Set(panes.map(\.projectPath))

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Routing identity (projectID) is restamped to the destination so a
        // notification click navigates to the right workspace.
        #expect(tab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        // Session identity is untouched — the shells keep running under their
        // original names and paths (a remote pane would still kill over ssh).
        #expect(Set(tab.splitRoot.allPanes().map(\.sessionName)) == originalSessionNames)
        #expect(Set(tab.splitRoot.allPanes().map(\.projectPath)) == originalPaths)
    }

    @Test
    func moveTab_toIndex_inserts_at_slot_in_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // Give p2 two tabs so there's a middle slot to drop into.
        let dest = try #require(state.workspaces[p2.id])
        let d0 = dest.tabs[0].id
        let d1 = dest.createTab(projectPath: p2.path).id
        let moving = try #require(state.workspaces[p1.id]?.activeTab)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path, toIndex: 1)

        #expect(dest.tabs.map(\.id) == [d0, moving.id, d1])
        #expect(dest.activeTabID == moving.id)
        #expect(state.workspaces[p1.id]?.tabs.contains { $0.id == moving.id } == false)
    }

    @Test
    func reorderTab_moves_within_project_and_persists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let state = makeAppState(store: WorkspaceStore(fileURL: storeURL))
        let p = seedProject(state, name: "p", path: "/tmp")
        let ws = try #require(state.workspaces[p.id])
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: p.path).id

        state.reorderTab(t1, inProject: p.id, toIndex: 2)
        #expect(ws.tabs.map(\.id) == [t2, t1])

        // The reorder persisted: a fresh store reading the same file sees it.
        let reloaded = WorkspaceStore(fileURL: storeURL).load()
        let saved = try #require(reloaded.workspaces.first { $0.projectID == p.id })
        #expect(saved.tabs.map(\.id) == [t2, t1])
    }

    // MARK: - Busy-close confirmations

    @Test
    func requestCloseTab_with_idle_panes_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ws.createTab(projectPath: "/tmp")

        // No live surfaces in a unit test → needsConfirmQuit is unreachable →
        // not busy → closes without staging.
        state.requestCloseTab(tab.id, projectID: p.id)
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 1)
    }

    @Test
    func requestRemoveProject_idle_runs_removal_immediately() {
        let state = makeAppState()
        let p = seedProject(state)
        var removed = false
        state.requestRemoveProject(p.id) { removed = true }
        #expect(removed)
        #expect(state.pendingRemoveProject == nil)
    }

    @Test
    func pendingCloseTab_confirm_and_cancel() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ws.createTab(projectPath: "/tmp")

        // Stage manually (busy detection needs a live surface).
        state.pendingCloseTab = AppState.PendingCloseTab(tabID: tab.id, projectID: p.id)
        state.cancelPendingCloseTab()
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 2)

        state.pendingCloseTab = AppState.PendingCloseTab(tabID: tab.id, projectID: p.id)
        state.confirmPendingCloseTab()
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 1)
    }
}

/// Actor recording killed session names across the fire-and-forget kill tasks.
private actor KilledSessions {
    private(set) var names: Set<String> = []
    func append(_ name: String) {
        names.insert(name)
    }

    /// Wait until at least `count` distinct names have been recorded (or a
    /// generous timeout elapses). Waiting for the EXPECTED count — not merely
    /// "anything arrived" — means a slow second kill can't make a positive
    /// assertion pass before all kills have landed.
    func settle(expecting count: Int) async {
        for _ in 0 ..< 200 where names.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// For negative assertions ("nothing should have been killed"): wait a
    /// deterministic window so a late kill would have shown up, then the caller
    /// asserts emptiness. Named distinctly so its intent (and its inherent
    /// fixed-wait limitation) is explicit at the call site.
    func settleExpectingNone() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
