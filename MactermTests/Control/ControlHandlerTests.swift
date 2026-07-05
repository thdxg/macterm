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
            listSessionsWithClients: { entries },
            sessionLeaderPIDs: { leaders }
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
}
