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
        case "project.create": return try projectCreate(args)
        case "project.select": return try projectSelect(args)
        case "tab.list": return try tabList(args)
        case "tab.new": return try tabNew(args)
        case "tab.select": return try tabSelect(args)
        case "tab.close": return try tabClose(args)
        case "pane.list": return try paneList(args)
        case "pane.split": return try paneSplit(args)
        case "pane.focus": return try paneFocus(args)
        case "pane.close": return try paneClose(args)
        case "pane.run": return try paneRun(args)
        case "grid": return try grid(args)
        case "session.list": return try await sessionList()
        case "session.info": return try await sessionInfo(args)
        case "session.kill": return try await sessionKill(args)
        case "layout.apply": return try layoutApply(args)
        case "layout.save": return try layoutSave(args)
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
        let infos = tabs.flatMap { _, tab in
            tab.splitRoot.allPanes().map { paneInfo($0, in: tab, workspace: workspace) }
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

    // MARK: - Project mutations

    /// Create (or find) a project for a local path. Idempotent by canonical
    /// path — re-creating an existing project returns it instead of erroring,
    /// so scripted setups (the benchmark) can run unconditionally.
    private func projectCreate(_ args: ControlArgs) throws -> ControlData {
        guard let rawPath = args.path, !rawPath.isEmpty else {
            throw ControlError(code: .badRequest, message: "project.create requires a path")
        }
        guard let parsed = ProjectPath.parse(rawPath) else {
            throw ControlError(code: .badRequest, message: "\"\(rawPath)\" is not an absolute or ~-prefixed path")
        }
        guard case .local = parsed else {
            throw ControlError(
                code: .badRequest,
                message: "remote projects aren't supported yet (#104)",
                action: "pass a local directory path"
            )
        }
        let canonical = ProjectPath.canonicalLocal(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError(code: .notFound, message: "no directory at \(canonical)")
        }

        let project = projectStore.findOrCreate(
            name: args.name ?? (canonical as NSString).lastPathComponent,
            path: canonical
        )
        if args.select == true {
            // selectProject runs the same first-open path the sidebar does —
            // including auto-applying a matching central project file, so a
            // declared layout spawns its tabs.
            appState.selectProject(project)
        }
        return projectData(project)
    }

    private func projectSelect(_ args: ControlArgs) throws -> ControlData {
        guard args.project != nil else {
            throw ControlError(code: .badRequest, message: "project.select requires a project selector")
        }
        let project = try resolveProject(args.project)
        appState.selectProject(project)
        return projectData(project)
    }

    // MARK: - Tab mutations

    private func tabNew(_ args: ControlArgs) throws -> ControlData {
        let (project, workspace) = try resolveWorkspace(args)
        guard let tabID = appState.createTab(projectID: project.id, projectPath: project.path, command: args.run),
              let index = workspace.tabs.firstIndex(where: { $0.id == tabID })
        else {
            throw ControlError(code: .internalError, message: "tab creation failed")
        }
        return ControlData(tabs: [tabInfo(workspace.tabs[index], index: index + 1, in: workspace)])
    }

    private func tabSelect(_ args: ControlArgs) throws -> ControlData {
        guard args.tab != nil else {
            throw ControlError(code: .badRequest, message: "tab.select requires a tab selector")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let (index, tab) = try resolveTab(args, in: workspace)
        appState.selectTab(tab.id, projectID: project.id)
        return ControlData(tabs: [tabInfo(tab, index: index, in: workspace)])
    }

    private func tabClose(_ args: ControlArgs) throws -> ControlData {
        guard args.tab != nil else {
            throw ControlError(code: .badRequest, message: "tab.close requires a tab selector")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let (_, tab) = try resolveTab(args, in: workspace)
        // Closing kills the panes' zmx sessions. The UI stages a confirmation
        // dialog for busy tabs; a headless caller gets a typed `busy` error
        // instead — never a dialog the CLI can't answer.
        let busy = tab.splitRoot.allPanes().contains { $0.nsView?.needsConfirmQuit() == true }
        if busy, args.force != true {
            throw ControlError(
                code: .busy,
                message: "a pane in that tab has a running program (closing kills its session)",
                action: "re-run with --force to close anyway"
            )
        }
        appState.closeTab(tab.id, projectID: project.id)
        return ControlData()
    }

    // MARK: - Pane mutations

    private func paneSplit(_ args: ControlArgs) throws -> ControlData {
        let (project, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        let direction: SplitDirection
        switch args.direction ?? "auto" {
        case "right": direction = .horizontal
        case "down": direction = .vertical
        case "auto":
            // The UI's auto-split picks the longer on-screen axis from the
            // pane's live NSView bounds; a never-shown pane measures zero and
            // falls back to horizontal — same as TerminalTab.autoSplit.
            let bounds = target.pane.nsView?.bounds.size ?? .zero
            direction = bounds.height > bounds.width ? .vertical : .horizontal
        default:
            throw ControlError(code: .badRequest, message: "direction must be right, down, or auto")
        }
        guard let newID = appState.splitPane(
            target.pane.id, direction: direction, projectID: project.id, command: args.run
        ), let newPane = target.tab.splitRoot.findPane(id: newID)
        else {
            throw ControlError(code: .internalError, message: "split failed")
        }
        return ControlData(panes: [paneInfo(newPane, in: target.tab, workspace: workspace)])
    }

    private func paneFocus(_ args: ControlArgs) throws -> ControlData {
        let (project, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        // navigateToPane selects the containing tab, fronts the window, and
        // restores first responder — everything "focus" means for a human.
        appState.navigateToPane(target.pane.id, projectID: project.id)
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    private func paneClose(_ args: ControlArgs) throws -> ControlData {
        let (project, workspace) = try resolveWorkspace(args)
        guard args.pane != nil || args.session != nil else {
            throw ControlError(code: .badRequest, message: "pane.close requires a pane or session selector")
        }
        let target = try resolvePane(args, in: workspace)
        let busy = target.pane.nsView?.needsConfirmQuit() == true
        if busy, args.force != true {
            throw ControlError(
                code: .busy,
                message: "that pane has a running program (closing kills its session)",
                action: "re-run with --force to close anyway"
            )
        }
        appState.closePane(target.pane.id, projectID: project.id)
        return ControlData()
    }

    private func paneRun(_ args: ControlArgs) throws -> ControlData {
        guard let command = args.run, !command.isEmpty else {
            throw ControlError(code: .badRequest, message: "pane.run requires a command")
        }
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        guard let view = target.pane.nsView, view.sendText(command + "\n") else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    private func grid(_ args: ControlArgs) throws -> ControlData {
        guard let rows = args.rows, let cols = args.cols, rows >= 1, cols >= 1, rows * cols > 1 else {
            throw ControlError(code: .badRequest, message: "grid requires rows×cols with at least 2 cells")
        }
        let cellCap = 16
        guard rows * cols <= cellCap else {
            throw ControlError(code: .badRequest, message: "grid caps at \(cellCap) cells")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        let created = appState.makeGrid(
            target.pane.id, rows: rows, columns: cols, projectID: project.id, command: args.run
        )
        guard !created.isEmpty else {
            throw ControlError(code: .internalError, message: "grid produced no panes")
        }
        let infos = created.compactMap { id in
            target.tab.splitRoot.findPane(id: id).map { paneInfo($0, in: target.tab, workspace: workspace) }
        }
        return ControlData(panes: infos)
    }

    // MARK: - Session / layout mutations

    private func sessionKill(_ args: ControlArgs) async throws -> ControlData {
        guard let name = args.session, !name.isEmpty else {
            throw ControlError(code: .badRequest, message: "session.kill requires a session name")
        }
        guard let entries = await zmx.listSessionsWithClients() else {
            throw ControlError(code: .internalError, message: "zmx session listing unavailable")
        }
        guard entries.contains(where: { $0.name == name }) else {
            throw ControlError(
                code: .notFound,
                message: "no zmx session named \"\(name)\"",
                action: "run `macterm session list` to see live sessions"
            )
        }
        await zmx.killSession(name)
        return ControlData()
    }

    private func layoutApply(_ args: ControlArgs) throws -> ControlData {
        let project = try resolveProject(args.project)
        if let error = appState.applyLayout(project: project) {
            throw ControlError(code: .notFound, message: error.localizedDescription)
        }
        // A destructive reconcile is staged for UI confirmation; headless
        // callers either force it through or get a typed `busy` — the staged
        // dialog must never dangle waiting for a click that won't come.
        if appState.pendingLayoutApply != nil {
            if args.force == true {
                appState.confirmPendingLayoutApply()
            } else {
                appState.cancelPendingLayoutApply()
                throw ControlError(
                    code: .busy,
                    message: "applying would close panes and end their processes",
                    action: "re-run with --force to apply anyway"
                )
            }
        }
        return ControlData()
    }

    private func layoutSave(_ args: ControlArgs) throws -> ControlData {
        let project = try resolveProject(args.project)
        if let error = appState.saveLayout(project: project) {
            throw ControlError(code: .internalError, message: error.localizedDescription)
        }
        return ControlData()
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

    /// Resolve the pane target: `session` (restart-stable name, searched
    /// across the whole workspace), `pane` (UUID anywhere, or `pane:N` index
    /// within the resolved tab), else the focused pane of the active tab.
    /// `session` and `pane` together conflict — an explicit error, never a
    /// silent winner.
    private func resolvePane(_ args: ControlArgs, in workspace: Workspace) throws -> (tab: TerminalTab, pane: Pane) {
        if args.session != nil, args.pane != nil {
            throw ControlError(code: .badRequest, message: "pass either --session or --pane, not both")
        }
        if let session = args.session, !session.isEmpty {
            for tab in workspace.tabs {
                if let pane = tab.splitRoot.allPanes().first(where: { $0.sessionName == session }) {
                    return (tab, pane)
                }
            }
            throw ControlError(
                code: .notFound,
                message: "no pane in this project runs session \"\(session)\"",
                action: "run `macterm pane list` for live panes"
            )
        }
        if let selector = args.pane, !selector.isEmpty {
            if let id = UUID(uuidString: selector) {
                for tab in workspace.tabs {
                    if let pane = tab.splitRoot.findPane(id: id) { return (tab, pane) }
                }
                throw ControlError(code: .notFound, message: "no pane with id \(selector)")
            }
            let (_, tab) = try resolveTab(args, in: workspace)
            let panes = tab.splitRoot.allPanes()
            guard let index = parseIndex(selector, prefix: "pane"), panes.indices.contains(index - 1) else {
                throw ControlError(
                    code: .notFound,
                    message: "no pane \(selector) in that tab",
                    action: "run `macterm pane list` for indexes"
                )
            }
            return (tab, panes[index - 1])
        }
        // No pane selector: an explicit tab selector means "that tab's
        // focused pane"; otherwise the active tab's.
        let (_, tab) = try resolveTab(args, in: workspace)
        guard let focusedID = tab.focusedPaneID, let pane = tab.splitRoot.findPane(id: focusedID) else {
            throw ControlError(code: .notFound, message: "the tab has no focused pane")
        }
        return (tab, pane)
    }

    // MARK: - Shared projections

    private func projectData(_ project: Project) -> ControlData {
        let info = ControlProjectInfo(
            id: project.id.uuidString,
            name: project.name,
            path: project.path,
            active: project.id == appState.activeProjectID,
            loaded: appState.workspaces[project.id] != nil,
            tabCount: appState.workspaces[project.id]?.tabs.count
        )
        return ControlData(projects: [info])
    }

    private func tabInfo(_ tab: TerminalTab, index: Int, in workspace: Workspace) -> ControlTabInfo {
        ControlTabInfo(
            index: index,
            id: tab.id.uuidString,
            title: tab.sidebarTitle,
            active: tab.id == workspace.activeTabID,
            paneCount: tab.splitRoot.allPanes().count
        )
    }

    private func tabInfos(in workspace: Workspace) -> [ControlTabInfo] {
        zip(1..., workspace.tabs).map { index, tab in
            tabInfo(tab, index: index, in: workspace)
        }
    }

    private func paneInfo(_ pane: Pane, in tab: TerminalTab, workspace: Workspace) -> ControlPaneInfo {
        let panes = tab.splitRoot.allPanes()
        let paneIndex = (panes.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1
        let tabIndex = (workspace.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        return ControlPaneInfo(
            index: paneIndex,
            id: pane.id.uuidString,
            session: pane.sessionName,
            tabIndex: tabIndex,
            tabID: tab.id.uuidString,
            title: pane.displayTitle,
            process: pane.foregroundProcessName,
            cwd: pane.nsView?.currentPwd ?? pane.projectPath,
            focused: tab.id == workspace.activeTabID && pane.id == tab.focusedPaneID
        )
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
