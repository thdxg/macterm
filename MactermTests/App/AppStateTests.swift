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

        let restored = WorkspaceSerializer.restore(from: store.load(), validIDs: [project.id])
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

        let restored = WorkspaceSerializer.restore(from: store.load(), validIDs: [p1.id])
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

    /// Write a raw central project file into `store`'s directory.
    private func writeProjectFile(_ yaml: String, in store: ProjectFileStore, filename: String = "test.yaml") {
        try? FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try? yaml.write(to: store.directoryURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    /// Write a legacy in-repo `.macterm/layout.yaml` (deprecated seed path).
    private func writeLegacyLayout(_ yaml: String, at root: String) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".macterm/layout.yaml")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? yaml.write(to: url, atomically: true, encoding: .utf8)
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
    func first_open_imports_legacy_layout_into_central_store_and_applies() throws {
        // Deprecated seed path (#114): no central file + parseable in-repo
        // `.macterm/layout.yaml` → imported, then applied from the central
        // store. Remove alongside the legacy path next release.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeLegacyLayout("""
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, at: dir.path)

        let project = Project(name: "Legacy Proj", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Applied…
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        // …and imported: the central file now declares the project's path,
        // named by the project-name slug, with the tabs carried over.
        let imported = try #require(try files.loadFull(forProjectPath: dir.path))
        #expect(imported.name == "Legacy Proj")
        #expect(imported.tabs?.count == 1)
        #expect(files.find(forProjectPath: dir.path)?.url.lastPathComponent == "legacy_proj.yaml")
        // The in-repo file is left untouched (it's a seed, never deleted).
        #expect(LayoutFile.exists(atProjectRoot: dir.path))
    }

    @Test
    func first_open_with_unparseable_legacy_layout_surfaces_error_and_imports_nothing() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-legacybad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeLegacyLayout("tabs:\n  - split: { direction: horizontal, first: {} }\n", at: dir.path)

        let project = Project(name: "bad", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Error dialog staged, nothing imported, default workspace created.
        #expect(state.pendingLayoutError?.verb == "import")
        #expect(files.find(forProjectPath: dir.path) == nil)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
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
    func apply_layout_imports_legacy_for_already_open_project() throws {
        // The migration path for existing projects (#114): a restored
        // snapshot (here, a live workspace) suppresses the first-open import,
        // so an explicit Apply Layout must import the committed legacy file
        // itself — otherwise it stays unreachable for the whole deprecation
        // window. Remove alongside the legacy path next release.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-legacylive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "Existing", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
        writeLegacyLayout("""
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, at: dir.path)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingLayoutError == nil)
        // Imported into the central store, named by the project-name slug…
        #expect(files.find(forProjectPath: dir.path)?.url.lastPathComponent == "existing.yaml")
        // …and applied to the live workspace (non-destructive: the idle pane
        // is reused positionally, the command pane spawns).
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
    }

    @Test
    func apply_layout_with_unparseable_legacy_surfaces_import_error() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-legacylivebad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "Existing", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        writeLegacyLayout("tabs:\n  - split: { direction: horizontal, first: {} }\n", at: dir.path)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingLayoutError?.verb == "import")
        #expect(files.find(forProjectPath: dir.path) == nil)
    }

    // MARK: - saveLayout duplicate conflicts

    @Test
    func save_layout_warns_when_a_duplicate_file_shadows_the_save() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // Two hand-authored duplicates. The save replaces the first (bound)
        // one, but "bbb.yaml" survives and sorts before "proj.yaml" — so it
        // shadows what was just saved.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "bbb.yaml")

        state.saveLayoutPresentingError(project)

        let notice = try #require(state.pendingLayoutError)
        #expect(notice.title == "Layout saved with a conflict")
        #expect(notice.message.contains("bbb.yaml"))
        #expect(notice.message.contains("takes precedence"))
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

    // MARK: - Occlusion-aware quiet-settle

    // These drive `AppState.settleIfVisible` directly with an injected
    // occlusion closure, rather than the full `refreshAllForegroundProcesses`
    // tick. The tick also re-reads each pane's real foreground process (nil in
    // a unit test with no live surface, which clears the run source) and is
    // gated on the `Preferences.shared.showTabStatusIndicator` singleton —
    // mutating that global races the parallel test runner. Testing the guard
    // in isolation is both deterministic and a truer unit of what PR adds.

    /// A pane whose activity went quiet long ago (past the 3s settle window),
    /// so a visible settle resolves it to `.done` and an occluded one holds.
    private func quietRunningPane() -> Pane {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        pane.recordUserInteraction()
        pane.markTerminalActivity(at: Date().addingTimeInterval(-10))
        #expect(pane.executionState == .running)
        return pane
    }

    @Test
    func occluded_pane_does_not_quiet_settle() {
        let state = makeAppState()
        let pane = quietRunningPane()
        state.paneIsOccluded = { _ in true }

        state.settleIfVisible(pane)
        // 10s of silence, but the renderer was parked — silence proves
        // nothing, so the pane must stay running.
        #expect(pane.executionState == .running)
    }

    @Test
    func visible_pane_still_quiet_settles() {
        let state = makeAppState()
        let pane = quietRunningPane()
        state.paneIsOccluded = { _ in false }

        state.settleIfVisible(pane)
        #expect(pane.executionState == .done)
    }

    @Test
    func deoccluded_pane_gets_fresh_quiet_window_before_settling() {
        let state = makeAppState()
        let pane = quietRunningPane()

        // Occluded: no settle, and the pane is marked as having been occluded.
        state.paneIsOccluded = { _ in true }
        state.settleIfVisible(pane)
        #expect(pane.executionState == .running)

        // Now visible. The stale 10s-old activity timestamp must not settle it
        // instantly — a false `.done` would stick, since activity can never
        // revive a done pane. The window restarts instead.
        state.paneIsOccluded = { _ in false }
        state.settleIfVisible(pane)
        #expect(pane.executionState == .running)

        // With genuine quiet now elapsing from the reset window, it settles.
        pane.settleTerminalActivityIfQuiet(now: Date().addingTimeInterval(4))
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
            remoteForegroundComms: { _, _ in nil },
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
        let saved = try #require(reloaded.first { $0.projectID == p.id })
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
