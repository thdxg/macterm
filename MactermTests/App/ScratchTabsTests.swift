import Foundation
@testable import Macterm
import Testing

/// Scratch tabs (#665): the sentinel workspace, creation in home, moves in and
/// out of projects, a close that removes, and the snapshot round trip.
@MainActor
struct ScratchTabsTests {
    // MARK: - Setup helpers

    /// AppState with a temp-file store and a no-op zmx (a test must never
    /// fork the real zmx or reap the developer's live sessions).
    private func makeState(storeURL: URL? = nil) -> AppState {
        let storeURL = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-scratch-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-scratch-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.zmx = .noop
        state.incubatePane = { _ in }
        return state
    }

    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    private var scratchID: UUID { ScratchTabs.projectID }

    // MARK: - Identity

    @Test
    func sentinel_is_not_the_pinned_one_and_both_are_synthetic() {
        #expect(ScratchTabs.projectID != PinnedTabs.projectID)
        #expect(Project.synthetic(for: scratchID)?.name == ScratchTabs.displayName)
        #expect(Project.synthetic(for: PinnedTabs.projectID)?.name == PinnedTabs.displayName)
        #expect(Project.synthetic(for: UUID()) == nil)
        #expect(Project.isSynthetic(scratchID))
        #expect(!Project.isSynthetic(UUID()))
    }

    @Test
    func reserves_both_spellings_in_any_case_and_padding_only() {
        for name in ["Scratch Tabs", "scratch tabs", "SCRATCH TABS", " Scratch Tabs ", "scratch", "Scratch", "\tSCRATCH\n"] {
            #expect(ScratchTabs.reservesName(name), "\(name)")
            #expect(Project.reservesName(name), "\(name)")
        }
        for name in ["", "Scratch Tabs 2", "Scratchy", "tabs", "Pinned Tabs", ScratchTabs.projectID.uuidString] {
            #expect(!ScratchTabs.reservesName(name), "\(name)")
        }
        // The pinned name still goes through the shared test.
        #expect(Project.reservedNameMessage(for: "Pinned") == PinnedTabs.reservedNameMessage)
        #expect(Project.reservedNameMessage(for: "scratch") == ScratchTabs.reservedNameMessage)
        #expect(Project.reservedNameMessage(for: "api") == nil)
    }

    // MARK: - Creation

    @Test
    func createScratchTab_makes_the_workspace_with_one_tab_in_home_and_selects_it() throws {
        let state = makeState()
        #expect(state.scratchWorkspace == nil)
        #expect(!state.hasScratchTabs)

        let id = try #require(state.createScratchTab())

        let ws = try #require(state.scratchWorkspace)
        #expect(ws.tabs.map(\.id) == [id])
        #expect(ws.activeTabID == id)
        #expect(state.hasScratchTabs)
        #expect(state.activeProjectID == scratchID)
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.projectID == scratchID)
        #expect(pane.projectPath == ProjectPath.currentHome)
    }

    @Test
    func the_command_applies_without_a_project_where_newTab_does_not() throws {
        let state = makeState()
        let store = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-scratch-tests-projects-\(UUID().uuidString).json"))
        let ctx = AppCommandContext(appState: state, projectStore: store)
        #expect(state.activeProjectID == nil)
        // New Tab keeps its rule: nothing to act on without a project.
        #expect(AppCommand.newTab.action(in: ctx) == nil)

        let action = try #require(AppCommand.newScratchTab.action(in: ctx))
        action()

        #expect(state.scratchWorkspace?.tabs.count == 1)
        #expect(state.activeProjectID == scratchID)
        #expect(HotkeyAction.newScratchTab.defaultShortcut == "cmd+shift+t")
    }

    @Test
    func createScratchTab_without_focus_keeps_the_active_project() throws {
        let state = makeState()
        let p = seedProject(state)

        let id = try #require(state.createScratchTab(focus: false))

        #expect(state.activeProjectID == p.id)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [id])
    }

    @Test
    func ensureScratchWorkspace_starts_empty() {
        let state = makeState()
        state.ensureScratchWorkspace()
        #expect(state.scratchWorkspace?.tabs.isEmpty == true)
        #expect(!state.hasScratchTabs)
    }

    @Test
    func selectScratchTabs_selects_the_workspace_and_its_first_tab() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab(focus: false))
        state.scratchWorkspace?.activeTabID = nil
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)

        state.selectScratchTabs()

        #expect(state.activeProjectID == scratchID)
        #expect(state.scratchWorkspace?.activeTabID == id)
    }

    // MARK: - Moves

    @Test
    func moveTabToScratchTabs_rebinds_the_panes_and_leaves_the_project() throws {
        let state = makeState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let cwd = pane.projectPath

        state.moveTabToScratchTabs(tab.id, from: p.id)

        #expect(state.workspaces[p.id]?.tabs.isEmpty == true)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [tab.id])
        #expect(pane.projectID == scratchID)
        // The tab keeps its own working directory; only its row moves.
        #expect(pane.projectPath == cwd)
        #expect(state.activeProjectID == scratchID)
        #expect(state.pinnedRecords.isEmpty)
    }

    @Test
    func moveTab_from_scratch_into_a_project_is_a_plain_move() throws {
        let state = makeState()
        let p = seedProject(state)
        let id = try #require(state.createScratchTab())
        let pane = try #require(state.scratchWorkspace?.tabs.first?.splitRoot.allPanes().first)

        state.moveTab(id, from: scratchID, to: p.id, destPath: p.path)

        #expect(state.scratchWorkspace?.tabs.isEmpty == true)
        #expect(state.workspaces[p.id]?.tabs.map(\.id).contains(id) == true)
        #expect(pane.projectID == p.id)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func pinning_a_scratch_tab_records_its_origin_and_unpin_returns_it() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab())

        state.pinTab(id, fromProject: scratchID)
        #expect(state.pinnedRecords.map(\.id) == [id])
        #expect(state.pinnedRecords.first?.originProjectID == scratchID)
        #expect(state.scratchWorkspace?.tabs.isEmpty == true)

        state.unpinTab(id, projects: [])
        #expect(state.pinnedRecords.isEmpty)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [id])
        #expect(state.activeProjectID == scratchID)
    }

    @Test
    func unpin_with_no_project_and_no_scratch_origin_lands_in_the_scratch_workspace() throws {
        let state = makeState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.pinTab(tab.id, fromProject: p.id)

        // The origin project is gone from the list: the scratch workspace is
        // where every tab can live.
        state.unpinTab(tab.id, projects: [])

        #expect(state.pinnedRecords.isEmpty)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [tab.id])
    }

    // MARK: - Close

    @Test
    func closing_a_scratch_tab_removes_it_and_keeps_the_workspace() throws {
        let state = makeState()
        let first = try #require(state.createScratchTab())
        let second = try #require(state.createScratchTab())

        state.closeTab(second, projectID: scratchID)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [first])

        state.closeTab(first, projectID: scratchID)
        #expect(state.scratchWorkspace?.tabs.isEmpty == true)
        #expect(!state.hasScratchTabs)
        // Still the active workspace: the sidebar keeps the rows' place
        // while the user is there, and Cmd+T makes a new scratch tab.
        #expect(state.activeProjectID == scratchID)
    }

    // MARK: - Guards

    @Test
    func the_scratch_workspace_is_neither_unloaded_nor_removed() throws {
        let state = makeState()
        let id = try #require(state.createScratchTab())

        state.unloadProject(scratchID)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [id])

        state.removeProject(scratchID)
        #expect(state.scratchWorkspace?.tabs.map(\.id) == [id])
    }

    @Test
    func configuredProjectDirectory_is_home_for_the_scratch_workspace() {
        let state = makeState()
        #expect(state.configuredProjectDirectory(projectID: scratchID, projects: []) == ProjectPath.currentHome)
    }

    // MARK: - Persistence

    @Test
    func scratch_tabs_survive_a_snapshot_round_trip_without_a_project() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-scratch-tests-\(UUID().uuidString).json")
        let writer = makeState(storeURL: storeURL)
        let id = try #require(writer.createScratchTab())
        let session = try #require(writer.scratchWorkspace?.tabs.first?.splitRoot.allPanes().first?.sessionName)
        writer.saveWorkspaces()

        let reader = makeState(storeURL: storeURL)
        reader.restoreSelection(projects: [])

        let ws = try #require(reader.scratchWorkspace)
        #expect(ws.tabs.map(\.id) == [id])
        #expect(ws.activeTabID == id)
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.sessionName == session)
        #expect(pane.projectID == scratchID)
    }

    @Test
    func restore_lands_on_the_scratch_workspace_only_while_it_has_tabs() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-scratch-tests-\(UUID().uuidString).json")
        let priorActive = Preferences.shared.activeProjectID
        defer { Preferences.shared.activeProjectID = priorActive }

        let writer = makeState(storeURL: storeURL)
        let id = try #require(writer.createScratchTab())
        writer.saveWorkspaces()
        Preferences.shared.activeProjectID = scratchID

        let reader = makeState(storeURL: storeURL)
        reader.restoreSelection(projects: [])
        #expect(reader.activeProjectID == scratchID)
        #expect(reader.scratchWorkspace?.activeTabID == id)

        // Every scratch tab closed, then quit: the next launch selects nothing.
        writer.closeTab(id, projectID: scratchID)
        writer.saveWorkspaces()
        Preferences.shared.activeProjectID = scratchID
        let empty = makeState(storeURL: storeURL)
        empty.restoreSelection(projects: [])
        #expect(empty.activeProjectID == nil)
        #expect(empty.scratchWorkspace?.tabs.isEmpty == true)
    }
}
