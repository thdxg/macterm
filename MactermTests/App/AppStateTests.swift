import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateTests {
    // MARK: - Setup helpers

    /// Build an AppState with a temp-file workspace store so tests don't
    /// touch the user's real App Support data.
    private func makeAppState(store: WorkspaceStore? = nil) -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        return AppState(workspaceStore: store ?? WorkspaceStore(fileURL: tmp))
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

    private func writeLayout(_ yaml: String, at root: String) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".macterm/layout.yaml")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func selecting_project_with_layout_file_auto_applies_on_first_open() throws {
        let state = makeAppState()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-autoapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Layout exists *before* the project is first opened.
        writeLayout("""
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, at: dir.path)

        let project = Project(name: "auto", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Workspace built from the layout (one tab, two panes), not the default
        // single-pane workspace. Non-destructive on first open → no prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        #expect(state.pendingLayoutApply == nil)
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
    func layout_file_wins_over_restored_snapshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-layoutwins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "winner", path: dir.path, sortOrder: 0)

        // Pre-seed a saved snapshot for the project: a single-pane workspace.
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: storeURL)
        let snapshotWS = Workspace(projectID: project.id, projectPath: dir.path)
        store.save(WorkspaceSerializer.snapshot([project.id: snapshotWS]))

        // And a layout file declaring a two-pane split.
        writeLayout("""
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, at: dir.path)

        // Make it the active project so restore reopens it.
        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        // Restore: the layout file must win — the project's snapshot is skipped
        // and its workspace is rebuilt from the layout (two panes, not one).
        let state = makeAppState(store: store)
        state.restoreSelection(projects: [project])

        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
    }

    @Test
    func applyLayout_malformed_file_returns_error_and_does_not_apply() throws {
        let state = makeAppState()
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        // Invalid: a `split` mapping missing its `second` child.
        writeLayout("tabs:\n  - split: { direction: horizontal, first: {} }\n", at: root)
        let error = state.applyLayout(projectID: p.id, projectName: "proj", projectRoot: root)

        #expect(error != nil)
        // Workspace is untouched — same tabs, nothing spawned or closed.
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_missing_file_returns_error_and_does_not_apply() throws {
        let state = makeAppState()
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        let error = state.applyLayout(projectID: p.id, projectName: "proj", projectRoot: root)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_mismatched_project_name_prompts_confirmation() {
        let state = makeAppState()
        let (p, root) = seedProjectWithDir(state) // project name "proj"

        // Non-destructive layout (matches the single live pane) but saved for a
        // different project → should stage a confirmation rather than apply.
        writeLayout("name: OtherApp\ntabs:\n  - {}\n", at: root)
        let error = state.applyLayout(projectID: p.id, projectName: "proj", projectRoot: root)

        #expect(error == nil)
        #expect(state.pendingLayoutApply?.mismatchedProjectName == "OtherApp")
        #expect(state.pendingLayoutApply?.currentProjectName == "proj")
    }

    @Test
    func applyLayout_matching_project_name_applies_without_prompt() {
        let state = makeAppState()
        let (p, root) = seedProjectWithDir(state) // project name "proj"

        // Same project name + non-destructive → applies silently.
        writeLayout("name: proj\ntabs:\n  - {}\n", at: root)
        let error = state.applyLayout(projectID: p.id, projectName: "proj", projectRoot: root)

        #expect(error == nil)
        #expect(state.pendingLayoutApply == nil)
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
}
