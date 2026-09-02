import Foundation
@testable import Macterm
import Testing

@MainActor
struct ControlHandlerTests {
    // MARK: - Setup helpers (tempdir stores, mirroring AppStateTests)

    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-control-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-control-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
    }

    private func makeHandler(
        state: AppState? = nil,
        store: ProjectStore? = nil
    ) -> (ControlHandler, AppState, ProjectStore) {
        let appState = state ?? makeAppState()
        let projectStore = store ?? ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-control-tests-store-\(UUID().uuidString).json"))
        let handler = ControlHandler(appState: appState, projectStore: projectStore)
        return (handler, appState, projectStore)
    }

    private func seedProject(
        _ appState: AppState,
        _ projectStore: ProjectStore,
        name: String = "demo",
        path: String = "/tmp",
        select: Bool = true
    ) -> Project {
        let project = Project(name: name, path: path, sortOrder: projectStore.projects.count)
        projectStore.add(project)
        if select {
            appState.selectProject(project)
        }
        return project
    }

    private func request(_ command: String, args: ControlArgs? = nil) -> ControlRequest {
        ControlRequest(command: command, args: args)
    }

    // MARK: - Envelope behavior

    @Test
    func unknown_command_yields_typed_error_with_hint() async {
        let (handler, _, _) = makeHandler()
        let response = await handler.handle(request("frobnicate"))
        #expect(!response.ok)
        #expect(response.error?.code == .unknownCommand)
        #expect(response.error?.action?.contains("--help") == true)
    }

    @Test
    func undecodable_data_yields_bad_request() async {
        let (handler, _, _) = makeHandler()
        let raw = await handler.handle(Data("not json\n".utf8))
        let response = try? ControlProtocol.decodeResponse(raw)
        #expect(response?.ok == false)
        #expect(response?.error?.code == .badRequest)
    }

    @Test
    func response_echoes_request_id() async {
        let (handler, _, _) = makeHandler()
        var req = request("status")
        req.id = "custom-id-123"
        let response = await handler.handle(req)
        #expect(response.id == "custom-id-123")
    }

    // MARK: - status

    @Test
    func status_reports_pid_and_active_project() async {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore, name: "alpha")
        let response = await handler.handle(request("status"))
        #expect(response.ok)
        #expect(response.data?.status?.pid == getpid())
        #expect(response.data?.status?.activeProject == "alpha")
        #expect(response.data?.status?.activeProjectID == project.id.uuidString)
    }

    @Test
    func status_with_no_active_project_omits_it() async {
        let (handler, _, _) = makeHandler()
        let response = await handler.handle(request("status"))
        #expect(response.ok)
        #expect(response.data?.status?.activeProject == nil)
    }

    // MARK: - project.list

    @Test
    func project_list_marks_active_and_loaded() async {
        let (handler, appState, projectStore) = makeHandler()
        let selected = seedProject(appState, projectStore, name: "one")
        _ = seedProject(appState, projectStore, name: "two", select: false)
        let response = await handler.handle(request("project.list"))
        let projects = response.data?.projects
        #expect(projects?.count == 2)
        let one = projects?.first { $0.name == "one" }
        let two = projects?.first { $0.name == "two" }
        #expect(one?.active == true)
        #expect(one?.loaded == true)
        #expect(one?.id == selected.id.uuidString)
        #expect(one?.tabCount == 1)
        #expect(two?.active == false)
        #expect(two?.loaded == false)
        #expect(two?.tabCount == nil)
    }

    // MARK: - tab.list

    @Test
    func tab_list_defaults_to_active_project() async {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let response = await handler.handle(request("tab.list"))
        let tabs = response.data?.tabs
        #expect(tabs?.count == 2)
        #expect(tabs?.map(\.index) == [1, 2])
        // createTab selects the new tab.
        #expect(tabs?.last?.active == true)
        #expect(tabs?.allSatisfy { $0.paneCount == 1 } == true)
    }

    @Test
    func tab_list_resolves_project_by_name_index_and_uuid() async {
        let (handler, appState, projectStore) = makeHandler()
        let first = seedProject(appState, projectStore, name: "first")
        let second = seedProject(appState, projectStore, name: "second")
        appState.createTab(projectID: second.id, projectPath: second.path)

        for selector in ["first", "project:1", "1", first.id.uuidString] {
            let response = await handler.handle(request("tab.list", args: ControlArgs(project: selector)))
            #expect(response.data?.tabs?.count == 1, "selector \(selector)")
        }
        let response = await handler.handle(request("tab.list", args: ControlArgs(project: "second")))
        #expect(response.data?.tabs?.count == 2)
    }

    @Test
    func tab_list_unknown_project_is_not_found() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        let response = await handler.handle(request("tab.list", args: ControlArgs(project: "ghost")))
        #expect(response.error?.code == .notFound)
    }

    @Test
    func tab_list_unloaded_project_is_not_found_with_hint() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "loaded")
        _ = seedProject(appState, projectStore, name: "cold", select: false)
        let response = await handler.handle(request("tab.list", args: ControlArgs(project: "cold")))
        #expect(response.error?.code == .notFound)
        #expect(response.error?.action?.contains("project select") == true)
    }

    @Test
    func no_active_project_is_not_found() async {
        let (handler, _, _) = makeHandler()
        let response = await handler.handle(request("tab.list"))
        #expect(response.error?.code == .notFound)
    }

    @Test
    func ambiguous_project_name_is_reported() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "twin")
        _ = seedProject(appState, projectStore, name: "twin", select: false)
        let response = await handler.handle(request("tab.list", args: ControlArgs(project: "twin")))
        #expect(response.error?.code == .ambiguous)
    }

    // MARK: - pane.list

    @Test
    func pane_list_walks_splits_and_marks_focus() async {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.splitPane(direction: .horizontal, projectID: project.id)
        let response = await handler.handle(request("pane.list"))
        let panes = response.data?.panes
        #expect(panes?.count == 2)
        #expect(panes?.map(\.index) == [1, 2])
        #expect(panes?.allSatisfy { $0.tabIndex == 1 } == true)
        // splitPane focuses the new (second) pane.
        #expect(panes?.filter(\.focused).count == 1)
        #expect(panes?.last?.focused == true)
        #expect(panes?.allSatisfy { $0.session.hasPrefix("macterm-") } == true)
        #expect(panes?.allSatisfy { $0.cwd == project.path } == true)
        #expect(panes?.allSatisfy { $0.state == "idle" } == true)
    }

    @Test
    func pane_list_reports_running_and_done_states() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.isAppActive = { false }
        let pane = try #require(appState.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)

        pane.recordUserInteraction()
        pane.markCommandRunning()
        var response = await handler.handle(request("pane.list"))
        #expect(response.data?.panes?.first?.state == "running")

        pane.markCommandFinished()
        response = await handler.handle(request("pane.list"))
        #expect(response.data?.panes?.first?.state == "done")
    }

    @Test
    func pane_list_scopes_to_a_tab_selector() async {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        appState.splitPane(direction: .vertical, projectID: project.id)

        let all = await handler.handle(request("pane.list"))
        #expect(all.data?.panes?.count == 3)

        let scoped = await handler.handle(request("pane.list", args: ControlArgs(tab: "tab:2")))
        #expect(scoped.data?.panes?.count == 2)

        let first = await handler.handle(request("pane.list", args: ControlArgs(tab: "1")))
        #expect(first.data?.panes?.count == 1)

        let missing = await handler.handle(request("pane.list", args: ControlArgs(tab: "9")))
        #expect(missing.error?.code == .notFound)
    }

    // MARK: - session.list / session.info

    private func stubZmx(
        _ appState: AppState,
        entries: [ZmxSessionListParser.Entry]?,
        leaders: [String: pid_t] = [:]
    ) {
        appState.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { entries },
            sessionLeaderPIDs: { leaders },
            sessionListSnapshot: { entries.map { (entries: $0, leaders: leaders) } }
        )
    }

    @Test
    func session_list_maps_entries_and_live_panes() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        stubZmx(
            appState,
            entries: [
                .init(name: pane.sessionName, clients: 1),
                .init(name: "macterm-orphan-aaaabbbbcccc", clients: 0),
            ],
            leaders: [pane.sessionName: 4242]
        )
        let response = await handler.handle(request("session.list"))
        let sessions = response.data?.sessions
        #expect(sessions?.count == 2)
        let live = sessions?.first { $0.name == pane.sessionName }
        #expect(live?.paneID == pane.id.uuidString)
        #expect(live?.leaderPID == 4242)
        #expect(live?.clients == 1)
        let orphan = sessions?.first { $0.name == "macterm-orphan-aaaabbbbcccc" }
        #expect(orphan?.paneID == nil)
    }

    @Test
    func session_list_probe_failure_is_internal_error() async {
        let (handler, appState, _) = makeHandler()
        stubZmx(appState, entries: nil)
        let response = await handler.handle(request("session.list"))
        #expect(response.error?.code == .internalError)
    }

    @Test
    func session_info_finds_by_name_or_404s() async {
        let (handler, appState, _) = makeHandler()
        stubZmx(appState, entries: [.init(name: "macterm-x-000011112222", clients: 0)])

        let hit = await handler.handle(request("session.info", args: ControlArgs(session: "macterm-x-000011112222")))
        #expect(hit.ok)
        #expect(hit.data?.sessions?.count == 1)

        let miss = await handler.handle(request("session.info", args: ControlArgs(session: "macterm-y-000011112222")))
        #expect(miss.error?.code == .notFound)

        let empty = await handler.handle(request("session.info"))
        #expect(empty.error?.code == .badRequest)
    }

    // MARK: - project.create / project.select

    @Test
    func project_create_adds_and_optionally_selects() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let created = await handler.handle(request(
            "project.create", args: ControlArgs(path: dir.path, name: "fresh", select: true)
        ))
        #expect(created.ok)
        let info = created.data?.projects?.first
        #expect(info?.name == "fresh")
        #expect(info?.active == true)
        #expect(info?.loaded == true)
        #expect(projectStore.projects.count == 1)
        #expect(appState.activeProjectID?.uuidString == info?.id)

        // Not idempotent (one-project-per-directory removed): the same path
        // adds a distinct project rather than returning the existing one.
        let again = await handler.handle(request("project.create", args: ControlArgs(path: dir.path)))
        #expect(again.data?.projects?.first?.id != info?.id)
        #expect(projectStore.projects.count == 2)
    }

    @Test
    func project_create_rejects_bad_paths() async {
        let (handler, _, projectStore) = makeHandler()
        let relative = await handler.handle(request("project.create", args: ControlArgs(path: "dev/api")))
        #expect(relative.error?.code == .badRequest)
        let missing = await handler.handle(request(
            "project.create", args: ControlArgs(path: "/nonexistent-\(UUID().uuidString)")
        ))
        #expect(missing.error?.code == .notFound)
        let empty = await handler.handle(request("project.create"))
        #expect(empty.error?.code == .badRequest)
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func project_create_accepts_a_remote_spec_verbatim() async {
        // #104 shipped: a remote spec is a valid project path. Stored
        // verbatim — no local canonicalization or existence check applies,
        // and a wrong host/dir surfaces in the pane itself.
        let (handler, _, projectStore) = makeHandler()
        let response = await handler.handle(request(
            "project.create", args: ControlArgs(path: "dev@host:~/dev/api")
        ))
        #expect(response.ok)
        #expect(projectStore.projects.first?.path == "dev@host:~/dev/api")
        #expect(projectStore.projects.first?.isRemote == true)
    }

    @Test
    func project_select_switches_active() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "one")
        let two = seedProject(appState, projectStore, name: "two", select: false)
        let response = await handler.handle(request("project.select", args: ControlArgs(project: "two")))
        #expect(response.ok)
        #expect(appState.activeProjectID == two.id)

        let empty = await handler.handle(request("project.select"))
        #expect(empty.error?.code == .badRequest)
    }

    // MARK: - project.rename / project.remove

    @Test
    func project_rename_updates_name_and_persists() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "alpha")

        let response = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha", name: "beta")))
        #expect(response.ok)
        #expect(response.data?.projects?.first?.name == "beta")
        #expect(projectStore.projects.first?.name == "beta")
    }

    @Test
    func project_rename_trims_whitespace() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "alpha")

        let response = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha", name: "  trimmed  ")))
        #expect(response.ok)
        #expect(projectStore.projects.first?.name == "trimmed")
    }

    @Test
    func project_rename_validates_arguments() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "alpha")

        // Missing project
        let noProject = await handler.handle(request("project.rename", args: ControlArgs(name: "beta")))
        #expect(noProject.error?.code == .badRequest)

        // Missing name
        let noName = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha")))
        #expect(noName.error?.code == .badRequest)

        // Empty name
        let empty = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha", name: "   ")))
        #expect(empty.error?.code == .badRequest)

        // Reject pinned sentinel
        let pinned = await handler.handle(request("project.rename", args: ControlArgs(project: "pinned", name: "custom")))
        #expect(pinned.error?.code == .badRequest)

        // Refuse the sentinel's display name: `resolveProject` matches it
        // before any user project, so allowing it would strand this project's
        // name selector on the pinned workspace.
        let reserved = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha", name: "Pinned")))
        #expect(reserved.error?.code == .badRequest)
        let reservedCase = await handler.handle(request("project.rename", args: ControlArgs(project: "alpha", name: " pInNeD ")))
        #expect(reservedCase.error?.code == .badRequest)
        #expect(projectStore.projects.first?.name == "alpha")

        // Unknown project
        let unknown = await handler.handle(request("project.rename", args: ControlArgs(project: "nonexistent", name: "beta")))
        #expect(unknown.error?.code == .notFound)
    }

    @Test
    func project_remove_deletes_project_and_workspace() async {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore, name: "alpha")
        #expect(projectStore.projects.count == 1)
        #expect(appState.workspaces[project.id] != nil)

        let response = await handler.handle(request("project.remove", args: ControlArgs(project: "alpha")))
        #expect(response.ok)
        #expect(projectStore.projects.isEmpty)
        #expect(appState.workspaces[project.id] == nil)
    }

    @Test
    func project_remove_unloaded_project_succeeds() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore, name: "alpha", select: false)
        #expect(projectStore.projects.count == 1)

        let response = await handler.handle(request("project.remove", args: ControlArgs(project: "alpha")))
        #expect(response.ok)
        #expect(projectStore.projects.isEmpty)
    }

    @Test
    func project_remove_rejects_pinned_project() async {
        let (handler, _, _) = makeHandler()
        let response = await handler.handle(request("project.remove", args: ControlArgs(project: "pinned")))
        #expect(response.error?.code == .badRequest)
    }

    @Test
    func project_remove_validates_arguments() async {
        let (handler, _, _) = makeHandler()
        let empty = await handler.handle(request("project.remove"))
        #expect(empty.error?.code == .badRequest)

        let blank = await handler.handle(request("project.remove", args: ControlArgs(project: "   ")))
        #expect(blank.error?.code == .badRequest)

        let unknown = await handler.handle(request("project.remove", args: ControlArgs(project: "nonexistent")))
        #expect(unknown.error?.code == .notFound)
    }

    // MARK: - tab.new / tab.select / tab.close

    @Test
    func tab_new_creates_selects_and_reports() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let response = await handler.handle(request("tab.new", args: ControlArgs(run: "btop")))
        #expect(response.ok)
        let info = try #require(response.data?.tabs?.first)
        #expect(info.index == 2)
        #expect(info.active == true)
        let workspace = try #require(appState.workspaces[project.id])
        #expect(workspace.tabs.count == 2)
        // The declared command reaches the new tab's pane (spawns via
        // initial_input when the surface is created).
        #expect(workspace.tabs.last?.splitRoot.allPanes().first?.command == "btop")
    }

    @Test
    func tab_select_activates_by_index() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let workspace = try #require(appState.workspaces[project.id])
        let firstID = try #require(workspace.tabs.first?.id)

        let response = await handler.handle(request("tab.select", args: ControlArgs(tab: "tab:1")))
        #expect(response.ok)
        #expect(workspace.activeTabID == firstID)

        let empty = await handler.handle(request("tab.select"))
        #expect(empty.error?.code == .badRequest)
    }

    @Test
    func tab_close_removes_tab_and_kills_sessions() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let workspace = try #require(appState.workspaces[project.id])
        #expect(workspace.tabs.count == 2)

        let response = await handler.handle(request("tab.close", args: ControlArgs(tab: "tab:2")))
        #expect(response.ok)
        #expect(workspace.tabs.count == 1)

        let empty = await handler.handle(request("tab.close"))
        #expect(empty.error?.code == .badRequest)
    }

    // MARK: - tab.move (#224)

    /// `slot` is the tab's FINAL position, in both directions — the toward-end
    /// case is the one that would regress if the handler ever passed the slot
    /// straight into `Workspace.moveTab`'s pre-removal drop-offset coordinates
    /// (the tab would land one slot short).
    @Test
    func tab_move_places_tab_at_final_slot_in_both_directions() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let workspace = try #require(appState.workspaces[project.id])
        let ids = workspace.tabs.map(\.id)
        #expect(ids.count == 3)

        // Toward the front: third tab to slot 1.
        let front = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:3", slot: 1)))
        #expect(front.ok)
        #expect(front.data?.tabs?.first?.index == 1)
        #expect(workspace.tabs.map(\.id) == [ids[2], ids[0], ids[1]])

        // Toward the end: first tab (the just-moved one) to the last slot.
        let back = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:1", slot: 3)))
        #expect(back.ok)
        #expect(back.data?.tabs?.first?.index == 3)
        #expect(workspace.tabs.map(\.id) == ids)

        // Selection keys on the tab's UUID, so it follows the tab, not the slot.
        #expect(workspace.activeTabID == ids[2])
    }

    @Test
    func tab_move_same_slot_is_an_ok_noop() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let workspace = try #require(appState.workspaces[project.id])
        let before = workspace.tabs.map(\.id)

        let response = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:2", slot: 2)))
        #expect(response.ok)
        #expect(response.data?.tabs?.first?.index == 2)
        #expect(workspace.tabs.map(\.id) == before)
    }

    @Test
    func tab_move_validates_selector_and_slot() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.createTab(projectID: project.id, projectPath: project.path)
        let workspace = try #require(appState.workspaces[project.id])
        let before = workspace.tabs.map(\.id)

        let noTab = await handler.handle(request("tab.move", args: ControlArgs(slot: 1)))
        #expect(noTab.error?.code == .badRequest)

        let noSlot = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:1")))
        #expect(noSlot.error?.code == .badRequest)

        // Out-of-range slots are rejected, never silently clamped.
        for slot in [0, 3] {
            let outOfRange = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:1", slot: slot)))
            #expect(outOfRange.error?.code == .badRequest, "slot \(slot)")
        }

        let unknown = await handler.handle(request("tab.move", args: ControlArgs(tab: "tab:9", slot: 1)))
        #expect(unknown.error?.code == .notFound)

        #expect(workspace.tabs.map(\.id) == before)
    }

    // MARK: - tab.rename

    @Test
    func tab_rename_sets_custom_title_and_persists() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let workspace = try #require(appState.workspaces[project.id])
        let tab = try #require(workspace.tabs.first)
        #expect(tab.customTitle == nil)

        let response = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1", title: "Auth Worker")))
        #expect(response.ok)
        #expect(response.data?.tabs?.first?.title == "Auth Worker")
        #expect(tab.customTitle == "Auth Worker")
        #expect(tab.sidebarTitle == "Auth Worker")
    }

    @Test
    func tab_rename_reset_clears_custom_title_and_restores_auto_title() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let workspace = try #require(appState.workspaces[project.id])
        let tab = try #require(workspace.tabs.first)
        tab.customTitle = "Custom Name"

        let response = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1", reset: true)))
        #expect(response.ok)
        #expect(tab.customTitle == nil)
        #expect(tab.sidebarTitle == tab.autoTitle)
    }

    @Test
    func tab_rename_trims_whitespace() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let workspace = try #require(appState.workspaces[project.id])
        let tab = try #require(workspace.tabs.first)

        let response = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1", title: "  Trimmed Title  ")))
        #expect(response.ok)
        #expect(tab.customTitle == "Trimmed Title")
    }

    @Test
    func tab_rename_validates_arguments() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        _ = try #require(appState.workspaces[project.id])

        // Missing tab selector
        let noTab = await handler.handle(request("tab.rename", args: ControlArgs(title: "New Title")))
        #expect(noTab.error?.code == .badRequest)

        // Conflicting title and reset
        let conflict = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1", title: "New Title", reset: true)))
        #expect(conflict.error?.code == .badRequest)

        // Empty title
        let empty = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1", title: "   ")))
        #expect(empty.error?.code == .badRequest)

        // Missing both title and reset
        let neither = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:1")))
        #expect(neither.error?.code == .badRequest)

        // Unknown tab
        let unknown = await handler.handle(request("tab.rename", args: ControlArgs(tab: "tab:99", title: "Valid Title")))
        #expect(unknown.error?.code == .notFound)
    }

    // MARK: - pane.split / pane.focus / pane.close / pane.run

    @Test
    func pane_split_directions_and_command() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)

        let right = await handler.handle(request(
            "pane.split", args: ControlArgs(run: "yes", direction: "right")
        ))
        #expect(right.ok)
        let newInfo = try #require(right.data?.panes?.first)
        #expect(tab.splitRoot.allPanes().count == 2)
        let newID = try #require(UUID(uuidString: newInfo.id))
        let newPane = try #require(tab.splitRoot.findPane(id: newID))
        #expect(newPane.command == "yes")

        let bogus = await handler.handle(request("pane.split", args: ControlArgs(direction: "sideways")))
        #expect(bogus.error?.code == .badRequest)

        // Headless auto (no NSView bounds) falls back to horizontal.
        let auto = await handler.handle(request("pane.split", args: ControlArgs(direction: "auto")))
        #expect(auto.ok)
        #expect(tab.splitRoot.allPanes().count == 3)
    }

    @Test
    func pane_split_targets_session_selector() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)

        let response = await handler.handle(request(
            "pane.split", args: ControlArgs(session: source.sessionName, direction: "down")
        ))
        #expect(response.ok)
        #expect(tab.splitRoot.allPanes().count == 2)

        let both = await handler.handle(request(
            "pane.split", args: ControlArgs(pane: "pane:1", session: source.sessionName, direction: "down")
        ))
        #expect(both.error?.code == .badRequest)

        let unknown = await handler.handle(request(
            "pane.split", args: ControlArgs(session: "macterm-nope-000000000000", direction: "down")
        ))
        #expect(unknown.error?.code == .notFound)
    }

    @Test
    func pane_focus_selects_pane_across_tabs() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let workspace = try #require(appState.workspaces[project.id])
        let firstTab = try #require(workspace.tabs.first)
        let firstPane = try #require(firstTab.splitRoot.allPanes().first)
        appState.createTab(projectID: project.id, projectPath: project.path)
        #expect(workspace.activeTabID != firstTab.id)

        let response = await handler.handle(request(
            "pane.focus", args: ControlArgs(pane: firstPane.id.uuidString)
        ))
        #expect(response.ok)
        #expect(workspace.activeTabID == firstTab.id)
        #expect(firstTab.focusedPaneID == firstPane.id)
    }

    /// The direction makes the resolved pane the ORIGIN. The edge case is the
    /// contract a vim-tmux-navigator-style keymap depends on: no neighbour that
    /// way reports the origin unchanged and stays `ok`, so the caller can tell
    /// "didn't move" from "failed" without parsing an error.
    @Test
    func pane_focus_direction_moves_from_the_target_and_no_ops_at_the_edge() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let left = try #require(tab.splitRoot.allPanes().first)
        appState.splitPane(direction: .horizontal, projectID: project.id)
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let right = try #require(panes.last)
        #expect(tab.focusedPaneID == right.id)

        // From the right pane (the focused one, so no selector needed) leftward.
        let moved = await handler.handle(request("pane.focus", args: ControlArgs(direction: "left")))
        #expect(moved.ok)
        #expect(tab.focusedPaneID == left.id)
        #expect(moved.data?.panes?.first?.id == left.id.uuidString)

        // Already leftmost: ok, focus unchanged, and the reported pane is the
        // origin — that identity is how a caller detects the edge.
        let edge = await handler.handle(request("pane.focus", args: ControlArgs(direction: "left")))
        #expect(edge.ok)
        #expect(tab.focusedPaneID == left.id)
        #expect(edge.data?.panes?.first?.id == left.id.uuidString)

        // An explicit origin overrides the focused-pane default.
        let fromLeft = await handler.handle(request(
            "pane.focus", args: ControlArgs(pane: left.id.uuidString, direction: "right")
        ))
        #expect(fromLeft.ok)
        #expect(tab.focusedPaneID == right.id)

        // `auto` is split's vocabulary, not focus's.
        let bogus = await handler.handle(request("pane.focus", args: ControlArgs(direction: "auto")))
        #expect(bogus.error?.code == .badRequest)
    }

    @Test
    func pane_close_requires_explicit_target() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        appState.splitPane(direction: .horizontal, projectID: project.id)
        #expect(tab.splitRoot.allPanes().count == 2)

        let bare = await handler.handle(request("pane.close"))
        #expect(bare.error?.code == .badRequest)

        let second = try #require(tab.splitRoot.allPanes().last)
        let response = await handler.handle(request(
            "pane.close", args: ControlArgs(pane: second.id.uuidString)
        ))
        #expect(response.ok)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func pane_run_without_surface_is_no_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        // Headless test panes never create an NSView/surface, so this is the
        // no-surface path; the live path is covered by manual verification.
        let response = await handler.handle(request("pane.run", args: ControlArgs(run: "echo hi")))
        #expect(response.error?.code == .noSurface)

        let empty = await handler.handle(request("pane.run"))
        #expect(empty.error?.code == .badRequest)
    }

    @Test
    func pane_write_without_surface_is_no_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        let response = await handler.handle(request("pane.write", args: ControlArgs(text: "git status")))
        #expect(response.error?.code == .noSurface)

        let empty = await handler.handle(request("pane.write"))
        #expect(empty.error?.code == .badRequest)

        let emptyText = await handler.handle(request("pane.write", args: ControlArgs(text: "")))
        #expect(emptyText.error?.code == .badRequest)
    }

    @Test
    func pane_key_validates_chord_then_needs_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)

        // Missing chord → bad_request (before any pane resolution).
        let empty = await handler.handle(request("pane.key"))
        #expect(empty.error?.code == .badRequest)

        // Unparseable chord → bad_request, not a silent no-op.
        let bogus = await handler.handle(request("pane.key", args: ControlArgs(key: "ctrl+nope")))
        #expect(bogus.error?.code == .badRequest)

        // A well-formed chord parses; a headless test pane has no surface, so it
        // lands on no_surface — the same contract pane.run uses. The live
        // key-encoding path is covered by manual/CLI verification.
        for chord in ["ctrl+c", "escape", "up", "ctrl+\\"] {
            let response = await handler.handle(request("pane.key", args: ControlArgs(key: chord)))
            #expect(response.error?.code == .noSurface, "chord \(chord) should parse and reach no_surface")
        }
    }

    // MARK: - pane.inspect / pane.dump (#165)

    @Test
    func pane_inspect_without_surface_is_no_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        // Headless panes have no surface, hence no grid to report — the same
        // no_surface contract pane.run uses. The live payload (grid dims,
        // scrollback totals) is covered by manual verification against the app.
        let response = await handler.handle(request("pane.inspect"))
        #expect(response.error?.code == .noSurface)
    }

    @Test
    func pane_inspect_resolves_target_before_surface_check() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        // An unknown session selector must 404 (selector resolution), not fall
        // through to no_surface.
        let unknown = await handler.handle(request(
            "pane.inspect", args: ControlArgs(session: "macterm-nope-000000000000")
        ))
        #expect(unknown.error?.code == .notFound)
    }

    @Test
    func pane_dump_without_surface_is_no_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        let viewport = await handler.handle(request("pane.dump"))
        #expect(viewport.error?.code == .noSurface)

        let scrollback = await handler.handle(request("pane.dump", args: ControlArgs(scrollback: true)))
        #expect(scrollback.error?.code == .noSurface)
    }

    // MARK: - pane.zoom / pane.resize-split (#166)

    @Test
    func pane_zoom_toggles_tab_zoom_state() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        #expect(tab.zoomedPaneID == nil)

        let on = await handler.handle(request("pane.zoom", args: ControlArgs(pane: pane.id.uuidString)))
        #expect(on.ok)
        #expect(tab.zoomedPaneID == pane.id)

        let off = await handler.handle(request("pane.zoom", args: ControlArgs(pane: pane.id.uuidString)))
        #expect(off.ok)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test
    func pane_resize_split_sets_absolute_ratio() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        // A horizontal split gives a horizontal-axis branch at the root.
        appState.splitPane(direction: .horizontal, projectID: project.id)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let focused = try #require(tab.focusedPaneID)

        let response = await handler.handle(request(
            "pane.resize-split", args: ControlArgs(pane: focused.uuidString, axis: "horizontal", ratio: 0.3)
        ))
        #expect(response.ok)
        guard case let .split(branch) = tab.splitRoot else {
            Issue.record("root should be a split")
            return
        }
        #expect(abs(branch.ratio - 0.3) < 0.0001)
    }

    @Test
    func pane_resize_split_validates_axis_and_ratio() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        appState.splitPane(direction: .horizontal, projectID: project.id)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let focused = try #require(tab.focusedPaneID).uuidString

        let badAxis = await handler.handle(request(
            "pane.resize-split", args: ControlArgs(pane: focused, axis: "sideways", ratio: 0.3)
        ))
        #expect(badAxis.error?.code == .badRequest)

        let missingRatio = await handler.handle(request(
            "pane.resize-split", args: ControlArgs(pane: focused, axis: "horizontal")
        ))
        #expect(missingRatio.error?.code == .badRequest)

        let tooBig = await handler.handle(request(
            "pane.resize-split", args: ControlArgs(pane: focused, axis: "horizontal", ratio: 0.95)
        ))
        #expect(tooBig.error?.code == .badRequest)
    }

    @Test
    func pane_resize_split_wrong_axis_is_not_found() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        // Only a horizontal split exists; asking to resize a vertical split
        // around the pane finds no matching branch.
        appState.splitPane(direction: .horizontal, projectID: project.id)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)
        let focused = try #require(tab.focusedPaneID).uuidString

        let response = await handler.handle(request(
            "pane.resize-split", args: ControlArgs(pane: focused, axis: "vertical", ratio: 0.3)
        ))
        #expect(response.error?.code == .notFound)
    }

    // MARK: - pane.resize (debug-only, #167)

    #if DEBUG
    @Test
    func pane_resize_debug_verb_reachable_but_needs_surface() async {
        let (handler, appState, projectStore) = makeHandler()
        _ = seedProject(appState, projectStore)
        // In a DEBUG test build the verb dispatches (not unknown_command); a
        // headless pane has no surface, so it lands on no_surface.
        let response = await handler.handle(request("pane.resize", args: ControlArgs(rows: 24, cols: 80)))
        #expect(response.error?.code == .noSurface)

        let missing = await handler.handle(request("pane.resize"))
        #expect(missing.error?.code == .badRequest)
    }
    #endif

    // MARK: - grid

    @Test
    func grid_builds_cells_and_reports_created_panes() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let project = seedProject(appState, projectStore)
        let tab = try #require(appState.workspaces[project.id]?.activeTab)

        let response = await handler.handle(request(
            "grid", args: ControlArgs(run: "yes", rows: 2, cols: 2)
        ))
        #expect(response.ok)
        #expect(response.data?.panes?.count == 3)
        #expect(tab.splitRoot.allPanes().count == 4)

        let degenerate = await handler.handle(request("grid", args: ControlArgs(rows: 1, cols: 1)))
        #expect(degenerate.error?.code == .badRequest)

        let huge = await handler.handle(request("grid", args: ControlArgs(rows: 10, cols: 10)))
        #expect(huge.error?.code == .badRequest)
    }

    // MARK: - session.kill

    @Test
    func session_kill_verifies_then_kills() async {
        let (handler, appState, _) = makeHandler()
        let killed = KilledNames()
        appState.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [.init(name: "macterm-x-000011112222", clients: 0)] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [.init(name: "macterm-x-000011112222", clients: 0)], leaders: [:]) }
        )

        let miss = await handler.handle(request("session.kill", args: ControlArgs(session: "macterm-y-000011112222")))
        #expect(miss.error?.code == .notFound)
        #expect(await killed.names.isEmpty)

        let hit = await handler.handle(request("session.kill", args: ControlArgs(session: "macterm-x-000011112222")))
        #expect(hit.ok)
        #expect(await killed.names == ["macterm-x-000011112222"])
    }

    // MARK: - layout.apply / layout.save

    @Test
    func layout_save_then_apply_round_trips() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = Project(name: "roundtrip", path: dir.path, sortOrder: 0)
        projectStore.add(project)
        appState.selectProject(project)

        // No file yet → apply reports the miss.
        let before = await handler.handle(request("layout.apply"))
        #expect(before.error?.code == .notFound)

        let saved = await handler.handle(request("layout.save"))
        #expect(saved.ok)
        #expect(appState.projectFiles.find(forProjectPath: dir.path) != nil)

        // Reconciling the unchanged workspace against its own save is
        // non-destructive: applies cleanly without --force.
        let applied = await handler.handle(request("layout.apply"))
        #expect(applied.ok)
        #expect(appState.pendingLayoutApply == nil)
    }
}

/// Actor recording killed session names (kills hop through async closures).
private actor KilledNames {
    private(set) var names: Set<String> = []
    func append(_ name: String) {
        names.insert(name)
    }
}
