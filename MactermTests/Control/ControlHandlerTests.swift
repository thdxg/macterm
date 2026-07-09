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
        if select { appState.selectProject(project) }
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
            remoteForegroundComms: { _, _ in nil },
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

        // Idempotent: same path returns the existing project, adds nothing.
        let again = await handler.handle(request("project.create", args: ControlArgs(path: dir.path)))
        #expect(again.data?.projects?.first?.id == info?.id)
        #expect(projectStore.projects.count == 1)
    }

    @Test
    func project_create_rejects_bad_paths() async {
        let (handler, _, projectStore) = makeHandler()
        let relative = await handler.handle(request("project.create", args: ControlArgs(path: "dev/api")))
        #expect(relative.error?.code == .badRequest)
        let remote = await handler.handle(request("project.create", args: ControlArgs(path: "host:~/dev/api")))
        #expect(remote.error?.code == .badRequest)
        #expect(remote.error?.message.contains("#104") == true)
        let missing = await handler.handle(request(
            "project.create", args: ControlArgs(path: "/nonexistent-\(UUID().uuidString)")
        ))
        #expect(missing.error?.code == .notFound)
        let empty = await handler.handle(request("project.create"))
        #expect(empty.error?.code == .badRequest)
        #expect(projectStore.projects.isEmpty)
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
            remoteForegroundComms: { _, _ in nil },
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
