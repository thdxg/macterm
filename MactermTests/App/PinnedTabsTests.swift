import Foundation
@testable import Macterm
import Testing

/// Pinned tabs: the sentinel workspace, pin/unpin moves, the
/// can't-close rule, unload-on-session-death + restore-from-declaration, and
/// the `pinned.yaml` write/absorb contract.
@MainActor
struct PinnedTabsTests {
    // MARK: - Setup helpers

    private struct Fixture {
        let state: AppState
        let storeURL: URL
        let projectsDir: URL
    }

    /// AppState with temp-file stores and a no-op zmx (a test must never fork
    /// the real zmx or reap the developer's live sessions).
    private func makeFixture() -> Fixture {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.zmx = .noop
        // Never let the eager pinned launch warm REAL surfaces in the test
        // host (that would spawn actual shells).
        state.warmPane = { _ in }
        return Fixture(state: state, storeURL: storeURL, projectsDir: projectsDir)
    }

    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    private var pinnedID: UUID { PinnedTabs.projectID }

    // MARK: - Pin

    @Test
    func pinTab_moves_tab_into_pinned_workspace_and_records_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)

        fx.state.pinTab(tab.id, fromProject: p.id)

        #expect(fx.state.workspaces[p.id]?.tabs.isEmpty == true)
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.first?.originProjectID == p.id)
        #expect(pane.projectID == pinnedID)
        #expect(fx.state.activeProjectID == pinnedID)
    }

    @Test
    func pinTab_writes_pinned_yaml_with_marker_and_id() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)

        fx.state.pinTab(tab.id, fromProject: p.id)

        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("<pinned>"))
        // No wire-level ids — entries stay hand-editable.
        #expect(!text.contains(tab.id.uuidString))
    }

    @Test
    func moveTab_into_pinned_routes_to_pin() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)

        fx.state.moveTab(tab.id, from: p.id, to: pinnedID, destPath: "/anything")

        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func new_tab_created_inside_pinned_workspace_gets_a_record() throws {
        let fx = makeFixture()
        fx.state.selectPinnedProject()
        let tabID = try #require(
            fx.state.createTab(projectID: pinnedID, projectPath: PinnedTabs.fallbackRoot)
        )
        #expect(fx.state.pinnedRecords.map(\.id) == [tabID])
    }

    // MARK: - Unpin

    @Test
    func unpinTab_returns_loaded_tab_to_origin_project() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.workspaces[p.id]?.tabs.map(\.id) == [tab.id])
        #expect(tab.splitRoot.allPanes().first?.projectID == p.id)
    }

    @Test
    func unpinTab_unloaded_record_is_forgotten() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.unpinTab(record.id, projects: [])

        #expect(fx.state.pinnedRecords.isEmpty)
    }

    // MARK: - Remove from pinned

    @Test
    func removePinnedTab_idle_removes_record_and_live_tab() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.requestRemovePinnedTab(tab.id)

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pendingRemovePinnedTab == nil)
    }

    @Test
    func removePinnedTab_confirmation_flow_removes_on_confirm() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // Stage manually (busy detection needs a live surface — the same
        // convention as the other pending-confirmation tests).
        fx.state.pendingRemovePinnedTab = AppState.PendingRemovePinnedTab(tabID: tab.id)

        fx.state.cancelPendingRemovePinnedTab()
        #expect(fx.state.pendingRemovePinnedTab == nil)
        #expect(fx.state.pinnedRecords.count == 1)

        fx.state.pendingRemovePinnedTab = AppState.PendingRemovePinnedTab(tabID: tab.id)
        fx.state.confirmPendingRemovePinnedTab()
        #expect(fx.state.pendingRemovePinnedTab == nil)
        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
    }

    @Test
    func removePinnedTab_unloaded_forgets_the_record() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(layout: .pane(LayoutPane(run: "btop"))),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.requestRemovePinnedTab(record.id)

        #expect(fx.state.pinnedRecords.isEmpty)
    }

    // MARK: - Close = unload

    @Test
    func requestCloseTab_unloads_pinned_tab_keeping_the_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.requestCloseTab(tab.id, projectID: pinnedID)

        // Sessions end and the live tab goes — but the record (the dimmed
        // row, and its pinned.yaml entry) stays; unpin is the removal path.
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closeTabs_bulk_unloads_pinned_and_closes_normal_tabs() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let pinnedTab = ws.tabs[0]
        let normalTab = ws.createTab(projectPath: p.path)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)

        fx.state.closeTabs([
            (tabID: pinnedTab.id, projectID: pinnedID),
            (tabID: normalTab.id, projectID: p.id),
        ])

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [pinnedTab.id])
        #expect(fx.state.workspaces[p.id]?.tabs.isEmpty == true)
    }

    @Test
    func closePane_last_pane_of_pinned_tab_unloads_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.closePane(paneID, projectID: pinnedID)

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closePane_allows_inner_pane_of_pinned_split() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let newPane = try #require(tab.split(paneID: tab.splitRoot.allPanes()[0].id, direction: .horizontal))

        fx.state.closePane(newPane, projectID: pinnedID)

        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(fx.state.pinnedWorkspace?.tabs.count == 1)
    }

    // MARK: - Session death → unload → restore

    @Test
    func paneProcessExited_last_pane_unloads_tab_keeping_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: pinnedID)

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.isPinnedTabLoaded(tab.id) == false)
    }

    @Test
    func selectPinnedTab_rebuilds_unloaded_tab_from_declaration() throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]

        fx.state.selectPinnedTab(recordID)

        let tab = try #require(fx.state.pinnedWorkspace?.tabs.first)
        #expect(tab.id == recordID)
        #expect(tab.customTitle == "dev")
        let pane = try #require(tab.splitRoot.allPanes().first)
        #expect(pane.command == "npm run dev")
        #expect(pane.projectPath == "/tmp")
        #expect(fx.state.activeProjectID == pinnedID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == recordID)
    }

    @Test
    func paneProcessExited_in_normal_project_closes_as_before() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: p.id)

        #expect(ws.tabs.isEmpty)
    }

    // MARK: - Persistence + materialize

    @Test
    func pinned_tabs_persist_and_restore_as_records_with_live_snapshots() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        #expect(loaded.pinned.count == 1)
        #expect(loaded.pinned.first?.id == tab.id)
        #expect(loaded.pinned.first?.live != nil)
        #expect(loaded.pinned.first?.originProjectID == p.id)
        // The pinned workspace never serializes into the ordinary array.
        #expect(!loaded.workspaces.contains { $0.projectID == pinnedID })
    }

    @Test
    func materialize_respawns_dead_sessions_from_the_declaration() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let originalSession = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        // Second launch: a fresh state restoring the same file, with a zmx
        // whose listing says nothing survived. Pinned tabs are EAGER: the
        // dead tab respawns from its declaration at launch, not on click.
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var dead = ZmxClient.noop
        dead.isBundled = { true }
        dead.listSessionsWithClients = { [] }
        state2.zmx = dead
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.pinnedRecords.map(\.id) == [tab.id])
        #expect(state2.isPinnedTabLoaded(tab.id))
        // A respawn, not a reattach: fresh pane, fresh session identity.
        let pane = try #require(state2.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.sessionName != originalSession)
        #expect(pane.projectPath == "/tmp")
    }

    @Test
    func materialize_eager_loads_declaration_only_records_and_warms_them() async throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]
        var warmed: [UUID] = []
        fx.state.warmPane = { warmed.append($0.id) }

        await fx.state.materializeRestoredPinnedTabs()

        #expect(fx.state.isPinnedTabLoaded(recordID))
        let pane = try #require(fx.state.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.command == "npm run dev")
        #expect(warmed == [pane.id])
    }

    @Test
    func materialize_reattaches_surviving_sessions() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let sessionName = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var alive = ZmxClient.noop
        alive.isBundled = { true }
        alive.listSessionsWithClients = { [ZmxSessionListParser.Entry(name: sessionName, clients: 0)] }
        state2.zmx = alive
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.isPinnedTabLoaded(tab.id))
        // Session identity survives the round trip verbatim.
        let restoredPane = try #require(state2.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(restoredPane.sessionName == sessionName)
    }

    @Test
    func materialize_failed_listing_reattaches_conservatively() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil } // probe failed → unknown
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        // Unknown must fail toward reattach, never toward respawn.
        #expect(state2.isPinnedTabLoaded(tab.id))
    }

    // MARK: - Declaration freshness

    @Test
    func foreground_change_schedules_a_declaration_refresh() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let pane = try #require(tab.splitRoot.allPanes().first)

        // First observation populates the stamp (counts as a change);
        // steady state schedules nothing; a new foreground does.
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
        pane.foregroundProcessName = "btop"
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
    }

    @Test
    func persistRefreshedPinnedDeclarations_recaptures_and_rewrites_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // The declaration was captured at pin time; a later change to the tab
        // (a rename stands in for a started process, which needs a live
        // surface to observe) must reach both the record and pinned.yaml.
        tab.customTitle = "renamed"
        fx.state.persistRefreshedPinnedDeclarations()

        #expect(fx.state.pinnedRecords.first?.declaration.name == "renamed")
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("renamed"))
    }

    // MARK: - pinned.yaml reconcile / absorb

    @Test
    func launch_reconcile_adds_file_entries_as_unloaded_records() throws {
        let fx = makeFixture()
        try fx.state.pinnedLayoutStore.write(tabs: [
            LayoutTab(name: "hand-added", layout: .pane(LayoutPane(cwd: "~/dev", run: "btop"))),
        ])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.count == 1)
        #expect(fx.state.pinnedRecords.first?.declaration.name == "hand-added")
        #expect(fx.state.isPinnedTabLoaded(fx.state.pinnedRecords[0].id) == false)
    }

    @Test
    func launch_reconcile_drops_unloaded_records_removed_from_file() throws {
        let fx = makeFixture()
        let keep = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "keep", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        let removed = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "removed", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [keep, removed]
        try fx.state.pinnedLayoutStore.write(tabs: [keep.declaration])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [keep.id])
    }

    @Test
    func launch_reconcile_unpins_restorable_live_tab_removed_from_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        // Next launch: the user deleted the entry while the app was closed.
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        state2.zmx = .noop
        try state2.pinnedLayoutStore.write(tabs: [])
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        state2.reconcilePinnedLayoutAtLaunch(projects: [p])

        #expect(state2.pinnedRecords.isEmpty)
        // Honored as a MOVE: the tab landed in its origin project.
        #expect(state2.workspaces[p.id]?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func launch_reconcile_absent_file_keeps_records_and_materializes_file() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "mine", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [record.id])
        #expect(FileManager.default.fileExists(atPath: fx.state.pinnedLayoutStore.fileURL.path))
    }

    @Test
    func invalid_pinned_yaml_suspends_writes_and_preserves_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id) // creates a valid file

        // The user breaks the file mid-edit.
        let broken = "path: <pinned>\ntabs: [ not yaml {"
        try broken.write(to: fx.state.pinnedLayoutStore.fileURL, atomically: true, encoding: .utf8)

        // A membership change would normally rewrite — it must not clobber.
        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedLayoutSuspended)
        let onDisk = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(onDisk == broken)
    }

    @Test
    func external_addition_is_absorbed_before_the_next_write() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let first = ws.tabs[0]
        let second = ws.createTab(projectPath: p.path)
        fx.state.pinTab(first.id, fromProject: p.id)

        // Hand-edit while running: append an entry. The existing entry is
        // matched back by content (no wire-level ids).
        try fx.state.pinnedLayoutStore.write(tabs: [
            fx.state.pinnedRecords[0].declaration,
            LayoutTab(name: "external", layout: .pane(LayoutPane(run: "htop"))),
        ])

        // Next membership change triggers a write, which absorbs first.
        fx.state.pinTab(second.id, fromProject: p.id)

        #expect(fx.state.pinnedRecords.count == 3)
        #expect(fx.state.pinnedRecords.contains { $0.declaration.name == "external" })
        // The absorbed entry survived the rewrite too.
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("external"))
    }

    // MARK: - Keyboard navigation

    @Test
    func nextTabInProject_cycles_pinned_records_and_restores_unloaded_ones() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let unloadedID = UUID()
        fx.state.pinnedRecords.append(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        ))

        fx.state.selectNextTab(projectID: PinnedTabs.projectID)

        // Landed on the unloaded record and restored it.
        #expect(fx.state.pinnedWorkspace?.activeTabID == unloadedID)
        #expect(fx.state.isPinnedTabLoaded(unloadedID))

        fx.state.selectPreviousTab(projectID: PinnedTabs.projectID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == tab.id)
    }

    // MARK: - Global cycling

    @Test
    func selectGlobalTab_cycles_through_pinned_first() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let pinnedTab = ws.tabs[0]
        let projectTab = ws.createTab(projectPath: p.path)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)
        fx.state.selectPinnedTab(pinnedTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])

        #expect(fx.state.activeProjectID == p.id)
        #expect(fx.state.workspaces[p.id]?.activeTabID == projectTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])
        #expect(fx.state.activeProjectID == pinnedID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == pinnedTab.id)
    }
}
