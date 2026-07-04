import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ControlHandler")

/// Dispatches decoded control-socket requests into app state. Pure
/// translate-and-delegate: every operation calls the same `AppState` /
/// `ProjectStore` / `ZmxClient` methods the UI uses — no business logic of
/// its own. Injectable stores make it fully testable with the tempdir
/// pattern used by `AppStateTests`.
@MainActor
final class ControlHandler {
    private let appState: AppState
    private let projectStore: ProjectStore
    /// Follows `appState.zmx` so tests that stub the client (the established
    /// AppStateTests pattern) drive this handler too.
    private var zmx: ZmxClient { appState.zmx }

    init(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
    }

    /// Data-level entry point for `ControlSocketServer`: decode, dispatch,
    /// encode. Never throws — every failure becomes an error response.
    func handle(_ raw: Data) async -> Data {
        let request: ControlRequest
        do {
            request = try ControlProtocol.decodeRequest(raw)
        } catch {
            return ControlProtocol.encode(.failure(
                id: "",
                error: ControlError(code: .badRequest, message: "undecodable request: \(error.localizedDescription)")
            ))
        }
        let response = await handle(request)
        return ControlProtocol.encode(response)
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        logger.debug("control request: \(request.command, privacy: .public)")
        do {
            let data = try await dispatch(request)
            return .success(id: request.id, data: data)
        } catch let error as ControlError {
            return .failure(id: request.id, error: error)
        } catch {
            return .failure(
                id: request.id,
                error: ControlError(code: .internalError, message: error.localizedDescription)
            )
        }
    }

    private func dispatch(_ request: ControlRequest) async throws -> ControlData {
        let args = request.args ?? ControlArgs()
        switch request.command {
        case "status": return status()
        case "project.list": return projectList()
        case "tab.list": return try tabList(args)
        case "pane.list": return try paneList(args)
        case "session.list": return try await sessionList()
        case "session.info": return try await sessionInfo(args)
        default:
            throw ControlError(
                code: .unknownCommand,
                message: "unknown command \"\(request.command)\"",
                action: "run `macterm --help` for the supported commands"
            )
        }
    }

    // MARK: - Queries

    private func status() -> ControlData {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let active = projectStore.projects.first { $0.id == appState.activeProjectID }
        return ControlData(status: ControlStatusInfo(
            version: version,
            pid: getpid(),
            activeProject: active?.name,
            activeProjectID: active?.id.uuidString
        ))
    }

    private func projectList() -> ControlData {
        let infos = projectStore.projects.map { project in
            ControlProjectInfo(
                id: project.id.uuidString,
                name: project.name,
                path: project.path,
                active: project.id == appState.activeProjectID,
                // "Loaded" = a workspace exists (tabs/panes addressable over
                // this protocol) — NOT `AppState.isProjectLoaded`, which asks
                // whether live terminal *surfaces* exist and is false for a
                // restored-but-never-shown project.
                loaded: appState.workspaces[project.id] != nil,
                tabCount: appState.workspaces[project.id]?.tabs.count
            )
        }
        return ControlData(projects: infos)
    }

    private func tabList(_ args: ControlArgs) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        return ControlData(tabs: tabInfos(in: workspace))
    }

    private func paneList(_ args: ControlArgs) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        let tabs: [(Int, TerminalTab)]
        if args.tab != nil {
            let (index, tab) = try resolveTab(args, in: workspace)
            tabs = [(index, tab)]
        } else {
            tabs = Array(zip(1..., workspace.tabs))
        }
        var infos: [ControlPaneInfo] = []
        for (tabIndex, tab) in tabs {
            for (paneIndex, pane) in zip(1..., tab.splitRoot.allPanes()) {
                infos.append(ControlPaneInfo(
                    index: paneIndex,
                    id: pane.id.uuidString,
                    session: pane.sessionName,
                    tabIndex: tabIndex,
                    tabID: tab.id.uuidString,
                    title: pane.displayTitle,
                    process: pane.foregroundProcessName,
                    cwd: pane.nsView?.currentPwd ?? pane.projectPath,
                    focused: tab.id == workspace.activeTabID && pane.id == tab.focusedPaneID
                ))
            }
        }
        return ControlData(panes: infos)
    }

    private func sessionList() async throws -> ControlData {
        guard let entries = await zmx.listSessionsWithClients() else {
            throw ControlError(
                code: .internalError,
                message: "zmx session listing unavailable",
                action: "check Settings → session persistence for details"
            )
        }
        let leaders = await zmx.sessionLeaderPIDs()
        let paneBySession = paneIDsBySessionName()
        let infos = entries.map { entry in
            ControlSessionInfo(
                name: entry.name,
                clients: entry.clients,
                leaderPID: leaders[entry.name],
                paneID: paneBySession[entry.name]
            )
        }
        return ControlData(sessions: infos)
    }

    private func sessionInfo(_ args: ControlArgs) async throws -> ControlData {
        guard let name = args.session, !name.isEmpty else {
            throw ControlError(code: .badRequest, message: "session.info requires a session name")
        }
        let data = try await sessionList()
        guard let match = data.sessions?.first(where: { $0.name == name }) else {
            throw ControlError(
                code: .notFound,
                message: "no zmx session named \"\(name)\"",
                action: "run `macterm session list` to see live sessions"
            )
        }
        return ControlData(sessions: [match])
    }

    // MARK: - Selector resolution

    /// Resolve the project selector (name, UUID, or 1-based list index) to a
    /// project with a live workspace; defaults to the active project.
    private func resolveWorkspace(_ args: ControlArgs) throws -> (Project, Workspace) {
        let project = try resolveProject(args.project)
        guard let workspace = appState.workspaces[project.id] else {
            throw ControlError(
                code: .notFound,
                message: "project \"\(project.name)\" has no loaded workspace",
                action: "select it first: `macterm project select \(project.name)`"
            )
        }
        return (project, workspace)
    }

    private func resolveProject(_ selector: String?) throws -> Project {
        guard let selector, !selector.isEmpty else {
            guard let active = projectStore.projects.first(where: { $0.id == appState.activeProjectID }) else {
                throw ControlError(
                    code: .notFound,
                    message: "no active project",
                    action: "pass --project or select one in the app"
                )
            }
            return active
        }
        let projects = projectStore.projects
        if let id = UUID(uuidString: selector), let match = projects.first(where: { $0.id == id }) {
            return match
        }
        if let index = parseIndex(selector, prefix: "project"), projects.indices.contains(index - 1) {
            return projects[index - 1]
        }
        let byName = projects.filter { $0.name == selector }
        switch byName.count {
        case 1: return byName[0]
        case 0:
            throw ControlError(
                code: .notFound,
                message: "no project matches \"\(selector)\"",
                action: "run `macterm project list`"
            )
        default:
            throw ControlError(
                code: .ambiguous,
                message: "\(byName.count) projects are named \"\(selector)\"",
                action: "target by UUID from `macterm project list --json`"
            )
        }
    }

    /// Resolve the tab selector (1-based index, `tab:N` ref, UUID, or exact
    /// title) within a workspace.
    private func resolveTab(_ args: ControlArgs, in workspace: Workspace) throws -> (Int, TerminalTab) {
        guard let selector = args.tab, !selector.isEmpty else {
            guard let active = workspace.activeTab,
                  let index = workspace.tabs.firstIndex(where: { $0.id == active.id })
            else {
                throw ControlError(code: .notFound, message: "the workspace has no active tab")
            }
            return (index + 1, active)
        }
        if let id = UUID(uuidString: selector),
           let index = workspace.tabs.firstIndex(where: { $0.id == id })
        {
            return (index + 1, workspace.tabs[index])
        }
        if let index = parseIndex(selector, prefix: "tab"), workspace.tabs.indices.contains(index - 1) {
            return (index, workspace.tabs[index - 1])
        }
        let byTitle = workspace.tabs.enumerated().filter { $0.element.sidebarTitle == selector }
        switch byTitle.count {
        case 1: return (byTitle[0].offset + 1, byTitle[0].element)
        case 0:
            throw ControlError(
                code: .notFound,
                message: "no tab matches \"\(selector)\"",
                action: "run `macterm tab list`"
            )
        default:
            throw ControlError(
                code: .ambiguous,
                message: "\(byTitle.count) tabs are titled \"\(selector)\"",
                action: "target by index or UUID from `macterm tab list --json`"
            )
        }
    }

    /// Accepts `3` or `prefix:3` (the ref form the CLI renders).
    private func parseIndex(_ selector: String, prefix: String) -> Int? {
        var text = Substring(selector)
        if text.hasPrefix("\(prefix):") { text = text.dropFirst(prefix.count + 1) }
        guard let value = Int(text), value >= 1 else { return nil }
        return value
    }

    // MARK: - Shared projections

    private func tabInfos(in workspace: Workspace) -> [ControlTabInfo] {
        zip(1..., workspace.tabs).map { index, tab in
            ControlTabInfo(
                index: index,
                id: tab.id.uuidString,
                title: tab.sidebarTitle,
                active: tab.id == workspace.activeTabID,
                paneCount: tab.splitRoot.allPanes().count
            )
        }
    }

    private func paneIDsBySessionName() -> [String: String] {
        var map: [String: String] = [:]
        for workspace in appState.workspaces.values {
            for tab in workspace.tabs {
                for pane in tab.splitRoot.allPanes() {
                    map[pane.sessionName] = pane.id.uuidString
                }
            }
        }
        return map
    }
}
