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
        case "project.rename": return try projectRename(args)
        case "project.remove": return try projectRemove(args)
        case "tab.list": return try tabList(args)
        case "tab.new": return try tabNew(args)
        case "tab.select": return try tabSelect(args)
        case "tab.move": return try tabMove(args)
        case "tab.rename": return try tabRename(args)
        case "tab.close": return try tabClose(args)
        case "pane.list": return try paneList(args)
        case "pane.inspect": return try paneInspect(args)
        case "pane.dump": return try paneDump(args)
        case "pane.split": return try paneSplit(args)
        case "pane.focus": return try paneFocus(args)
        case "pane.close": return try paneClose(args)
        case "pane.run": return try paneRun(args)
        case "pane.key": return try paneKey(args)
        case "pane.zoom": return try paneZoom(args)
        case "pane.resize-split": return try paneResizeSplit(args)
        #if DEBUG
        case "pane.resize": return try paneResize(args)
        case "pane.move": return try paneMove(args)
        case "tab.merge": return try tabMerge(args)
        #endif
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

    /// Read-only terminal-core snapshot for a single pane (#165). Needs a live
    /// surface: a never-shown pane has no dimensions to report, so it's the
    /// same `no_surface` contract `pane.run` uses.
    private func paneInspect(_ args: ControlArgs) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        let pane = target.pane
        guard let view = pane.nsView, let size = view.surfaceSize else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        let snap = view.scrollbarSnapshot
        // The alt-screen heuristic mirrors SurfaceScrollView.canHandleScrollbackWheel:
        // `total > len` means there IS scrollback (normal screen); otherwise
        // we're on the alt screen / a fresh prompt. Undefined until a snapshot
        // arrives, so it tracks the snapshot's own nil-ness.
        let altScreen = snap.map { $0.total <= $0.len }
        let pid = ProcessInspector.resolvedForegroundPID(forPane: pane)
        let argv = pid.flatMap { ProcessInspector.argv(pid: $0) }
        let inspect = ControlPaneInspect(
            id: pane.id.uuidString,
            session: pane.sessionName,
            cols: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPx: Int(size.cell_width_px),
            cellHeightPx: Int(size.cell_height_px),
            widthPx: Int(size.width_px),
            heightPx: Int(size.height_px),
            scrollbackTotal: snap?.total,
            scrollbackOffset: snap?.offset,
            scrollbackLen: snap?.len,
            altScreen: altScreen,
            contentScale: view.window.map { Double($0.backingScaleFactor) },
            foregroundPID: pid,
            foregroundArgv: argv,
            processExited: view.processExited,
            // The pane-level signal, not the raw surface one — `pane inspect`
            // must report exactly what the close guards read, and for a
            // remote pane the surface's own verdict is meaningless (the local
            // ssh client reads as a perpetually running program).
            needsConfirmQuit: pane.needsConfirmClose
        )
        return ControlData(inspect: inspect)
    }

    /// Dump a pane's terminal cell text (#165): the viewport by default, or the
    /// full scrollback with `scrollback: true`. Needs a live surface.
    private func paneDump(_ args: ControlArgs) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        let pane = target.pane
        let scrollback = args.scrollback == true
        guard let view = pane.nsView, let text = view.readText(scrollback: scrollback) else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        return ControlData(dump: ControlPaneDump(
            id: pane.id.uuidString,
            session: pane.sessionName,
            scrollback: scrollback,
            bytes: text.utf8.count,
            text: text
        ))
    }

    private func sessionList() async throws -> ControlData {
        // One `zmx ls` for both the client counts and the leader pids, instead
        // of two separate fork/execs.
        guard let snapshot = await zmx.sessionListSnapshot() else {
            throw ControlError(
                code: .internalError,
                message: "zmx session listing unavailable",
                action: "check Settings → session persistence for details"
            )
        }
        let entries = snapshot.entries
        let leaders = snapshot.leaders
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
        // A remote spec ([user@]host:dir, #104) is stored verbatim — there is
        // no local directory to canonicalize or existence-check; a wrong host
        // or dir surfaces in the pane itself (ssh's error / the cd
        // diagnostic), same as a sheet-created remote project.
        let canonical: String
        switch parsed {
        case .local:
            canonical = ProjectPath.canonicalLocal(rawPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw ControlError(code: .notFound, message: "no directory at \(canonical)")
            }
        case .remote:
            canonical = rawPath
        }

        // Always create — `project create` is not idempotent: re-running adds a
        // distinct project for the same directory. `--select` only activates
        // the just-created project; scripts that want create-or-select must
        // check `project list` first.
        let project = projectStore.create(
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
        if project.id == PinnedTabs.projectID {
            // The synthetic project must not go through `selectProject` — its
            // first-open auto-apply would match a layout file declaring the
            // home directory.
            appState.selectPinnedProject()
        } else {
            appState.selectProject(project)
        }
        return projectData(project)
    }

    /// Rename a project — the same `ProjectStore.rename` the sidebar row's
    /// inline edit calls, so both paths have identical reach: `projects.json`
    /// only. Layout files are deliberately untouched (nothing but an explicit
    /// Save Layout rewrites one), and a declaration matches on its `path:`
    /// rather than its filename, so a rename doesn't orphan it. The name IS a
    /// layout identity in one narrow case — the `ProjectSlug` tiebreaker that
    /// picks a project's own file when several projects share a `path:` — so
    /// renaming such a project changes which file it owns at the next save.
    private func projectRename(_ args: ControlArgs) throws -> ControlData {
        guard let selector = args.project, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError(
                code: .badRequest,
                message: "project.rename requires a project selector",
                action: "run `macterm project list` for targets"
            )
        }
        guard let rawName = args.name else {
            throw ControlError(
                code: .badRequest,
                message: "project.rename requires a new name",
                action: "pass the new name as the second argument"
            )
        }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlError(code: .badRequest, message: "project name cannot be empty")
        }
        let project = try resolveProject(selector)
        // Unreachable through the app (the sentinel is not a `ProjectStore`
        // row, so no sidebar row edits it) — but `resolveProject` accepts
        // `pinned`, so the CLI is the one way in and has to say no here.
        guard project.id != PinnedTabs.projectID else {
            throw ControlError(code: .badRequest, message: "the pinned section cannot be renamed")
        }
        // `resolveProject` matches the sentinel's display name BEFORE any user
        // project's, so a project renamed to it becomes unreachable by name
        // (UUID and index still work, but `--project Pinned` would silently
        // target the pinned workspace instead). Refuse rather than strand it.
        guard trimmed.lowercased() != PinnedTabs.displayName.lowercased() else {
            throw ControlError(
                code: .badRequest,
                message: "\"\(PinnedTabs.displayName)\" is reserved for the pinned-tabs workspace",
                action: "pick another name"
            )
        }
        projectStore.rename(id: project.id, to: trimmed)
        guard let updated = projectStore.projects.first(where: { $0.id == project.id }) else {
            throw ControlError(code: .internalError, message: "project rename failed")
        }
        return projectData(updated)
    }

    /// Drop a project's workspace and its `ProjectStore` entry — the same pair
    /// every in-app removal runs (sidebar row menu, bulk delete, palette,
    /// Settings → Projects), which is what makes the CLI removal reach exactly
    /// as far as theirs: panes' zmx sessions die, `projects.json` loses the
    /// row, and files on disk (the project directory, its layout declaration)
    /// are untouched. Those paths stage a confirmation dialog for a busy
    /// project; a headless caller gets a typed `busy` error instead — never a
    /// dialog the CLI can't answer. Same contract as `tab.close`.
    private func projectRemove(_ args: ControlArgs) throws -> ControlData {
        guard let selector = args.project, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError(
                code: .badRequest,
                message: "project.remove requires a project selector",
                action: "run `macterm project list` for targets"
            )
        }
        let project = try resolveProject(selector)
        // See `projectRename` — the sentinel is reachable only through this
        // selector, and tearing the pinned workspace down is never valid.
        guard project.id != PinnedTabs.projectID else {
            throw ControlError(code: .badRequest, message: "the pinned section cannot be removed")
        }

        // The same expression `AppState.requestRemoveProject` evaluates before
        // it decides to stage its dialog, so the CLI refuses exactly when the
        // app would have asked.
        let busy = appState.workspaces[project.id]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .contains(where: \.needsConfirmClose) ?? false

        if busy, args.force != true {
            throw ControlError(
                code: .busy,
                message: "a pane in that project has a running program (removing kills its sessions)",
                action: "re-run with --force to remove anyway"
            )
        }

        appState.removeProject(project.id)
        projectStore.remove(id: project.id)
        return ControlData()
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

    /// Reorder a tab within its project to an absolute slot (#224). `slot` is
    /// the tab's FINAL 1-based position — `tab move tab:4 2` makes it second —
    /// which `Workspace.moveTab` doesn't speak: it takes a drag-and-drop
    /// insertion offset in the pre-removal coordinate space, where a drop past
    /// the origin lands one slot earlier. So a downward move passes `slot`
    /// (final position + the removed tab's own vacated slot) and any other
    /// passes `slot - 1` (0-based conversion only).
    private func tabMove(_ args: ControlArgs) throws -> ControlData {
        guard args.tab != nil else {
            throw ControlError(code: .badRequest, message: "tab.move requires a tab selector")
        }
        guard let slot = args.slot else {
            throw ControlError(code: .badRequest, message: "tab.move requires a destination slot")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let (fromIndex, tab) = try resolveTab(args, in: workspace)
        // Reject out-of-range slots up front so the caller isn't silently
        // clamped — same contract as pane.resize-split's ratio bounds.
        guard slot >= 1, slot <= workspace.tabs.count else {
            throw ControlError(
                code: .badRequest,
                message: "slot must be between 1 and \(workspace.tabs.count)",
                action: "run `macterm tab list` for the current order"
            )
        }
        appState.reorderTab(tab.id, inProject: project.id, toIndex: slot > fromIndex ? slot : slot - 1)
        return ControlData(tabs: [tabInfo(tab, index: slot, in: workspace)])
    }

    private func tabRename(_ args: ControlArgs) throws -> ControlData {
        guard args.tab != nil else {
            throw ControlError(code: .badRequest, message: "tab.rename requires a tab selector")
        }
        if args.reset == true, args.title != nil {
            throw ControlError(code: .badRequest, message: "cannot specify both a title and --reset")
        }
        let newTitle: String?
        if args.reset == true {
            newTitle = nil
        } else if let rawTitle = args.title {
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ControlError(
                    code: .badRequest,
                    message: "tab title cannot be empty",
                    action: "pass --reset to restore automatic naming"
                )
            }
            newTitle = trimmed
        } else {
            throw ControlError(
                code: .badRequest,
                message: "tab.rename requires a title or --reset",
                action: "pass a title or --reset to restore automatic naming"
            )
        }

        let (_, workspace) = try resolveWorkspace(args)
        let (index, tab) = try resolveTab(args, in: workspace)

        tab.customTitle = newTitle
        appState.saveWorkspaces()

        return ControlData(tabs: [tabInfo(tab, index: index, in: workspace)])
    }

    private func tabClose(_ args: ControlArgs) throws -> ControlData {
        guard args.tab != nil else {
            throw ControlError(code: .badRequest, message: "tab.close requires a tab selector")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let (_, tab) = try resolveTab(args, in: workspace)
        // Closing kills the panes' zmx sessions. (For a PINNED tab, close is
        // an unload: sessions end but the record and its pinned.yaml entry
        // stay, and the next launch starts it again — unpin in the app is the
        // removal path.) The UI stages a confirmation dialog for busy tabs; a
        // headless caller gets a typed `busy` error instead — never a dialog
        // the CLI can't answer.
        let busy = tab.splitRoot.allPanes().contains(where: \.needsConfirmClose)
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
        // With a direction the resolved pane is the ORIGIN, not the
        // destination: move to its nearest neighbour that way. Same
        // `nearestPane` primitive the focus keybinds use, so a CLI move and a
        // keybind move can't pick different panes.
        var pane = target.pane
        if let raw = args.direction {
            let direction: PaneFocusDirection
            switch raw {
            case "left": direction = .left
            case "down": direction = .down
            case "up": direction = .up
            case "right": direction = .right
            default:
                throw ControlError(code: .badRequest, message: "direction must be left, down, up, or right")
            }
            // No neighbour that way is a successful no-op, NOT an error. The
            // caller is typically a program that already failed to move within
            // its own splits (a vim-tmux-navigator-style keymap) and is asking
            // whether Macterm can go further; at the outermost edge the answer
            // is simply "no". Returning the unchanged pane lets the caller see
            // that by comparing the reported session against its own.
            if let neighbour = target.tab.splitRoot.nearestPane(from: pane.id, direction: direction),
               let resolved = target.tab.splitRoot.findPane(id: neighbour)
            {
                pane = resolved
            }
        }
        // navigateToPane selects the containing tab, fronts the window, and
        // restores first responder — everything "focus" means for a human.
        appState.navigateToPane(pane.id, projectID: project.id)
        return ControlData(panes: [paneInfo(pane, in: target.tab, workspace: workspace)])
    }

    private func paneClose(_ args: ControlArgs) throws -> ControlData {
        let (project, workspace) = try resolveWorkspace(args)
        guard args.pane != nil || args.session != nil else {
            throw ControlError(code: .badRequest, message: "pane.close requires a pane or session selector")
        }
        let target = try resolvePane(args, in: workspace)
        let busy = target.pane.needsConfirmClose
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

    /// Paste a command line into a live pane's shell. The trailing newline is
    /// what submits it, and `submit: false` withholds exactly that — leaving
    /// the text on the prompt for a human to inspect, or for a TUI that
    /// submits on its own terms. One verb rather than two, because the two
    /// forms differ by that single character and nothing else.
    ///
    /// Withholding it is safe for execution tracking because `sendText` draws
    /// the same line internally: it records command-submission evidence for
    /// whatever it delivers but fires `onCommandSubmitted` only when the text
    /// carries a newline. So an unsubmitted paste leaves the evidence armed
    /// exactly as typing those characters would, and a following `pane.key`
    /// Return reads as a REAL submission rather than a bare prompt redraw —
    /// which is what keeps tab naming and execution state honest across a
    /// paste-then-Return pair.
    private func paneRun(_ args: ControlArgs) throws -> ControlData {
        guard let command = args.run, !command.isEmpty else {
            throw ControlError(code: .badRequest, message: "pane.run requires a command")
        }
        // Absent means submit: the flag only ever arrives as an explicit false.
        return try paneSendText(args, text: args.submit == false ? command : command + "\n")
    }

    /// Resolve the target pane and paste `text` into it, or report the
    /// `no_surface` miss.
    private func paneSendText(_ args: ControlArgs, text: String) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        guard let view = target.pane.nsView, view.sendText(text) else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    /// Send a single key chord to the pane through libghostty's key-encoding
    /// path (`GhosttyTerminalNSView.sendKey`) — the single-keypress counterpart
    /// to `pane.run`'s text paste. The chord uses the same `HotkeyRegistry`
    /// grammar as user keybinds (`ctrl+c`, `escape`, `up`, `ctrl+\`, and bare
    /// printables like `j` or `space`), so scripts can drive a TUI or interrupt
    /// a process, not just type a command. Requires a live surface, same
    /// `no_surface` contract.
    private func paneKey(_ args: ControlArgs) throws -> ControlData {
        guard let chord = args.key, !chord.isEmpty else {
            throw ControlError(code: .badRequest, message: "pane.key requires a key chord")
        }
        guard let shortcut = HotkeyRegistry.parseShortcut(chord) else {
            throw ControlError(
                code: .badRequest,
                message: "unrecognized key chord '\(chord)'",
                action: "use tokens like ctrl+c, escape, up, or ctrl+\\ (see `macterm pane key --help`)"
            )
        }
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        guard let view = target.pane.nsView,
              view.sendKey(keyCode: shortcut.keyCode, mods: shortcut.modifiers)
        else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    /// Toggle zoom on the target pane (#166) — the same `TerminalTab.toggleZoom`
    /// the Cmd+Shift+Enter keybind drives. Purely a layout-state change, so it
    /// needs no live surface; the pane just has to exist.
    private func paneZoom(_ args: ControlArgs) throws -> ControlData {
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        target.tab.toggleZoom(paneID: target.pane.id)
        appState.saveWorkspaces()
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    /// Set an absolute split ratio around the target pane (#166): adjusts the
    /// nearest ancestor branch whose direction matches `axis`. Deterministic
    /// counterpart to the keybind's relative nudge — lets scripts reproduce an
    /// exact geometry.
    private func paneResizeSplit(_ args: ControlArgs) throws -> ControlData {
        let axis: SplitDirection
        switch args.axis {
        case "horizontal",
             "h": axis = .horizontal
        case "vertical",
             "v": axis = .vertical
        default:
            throw ControlError(code: .badRequest, message: "axis must be horizontal or vertical")
        }
        guard let ratio = args.ratio else {
            throw ControlError(code: .badRequest, message: "pane.resize-split requires a ratio")
        }
        // The tree clamps to 0.15…0.85; reject wilder asks up front so the
        // caller isn't silently corrected.
        guard ratio >= 0.15, ratio <= 0.85 else {
            throw ControlError(code: .badRequest, message: "ratio must be between 0.15 and 0.85")
        }
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        guard target.tab.setSplitRatio(paneID: target.pane.id, axis: axis, ratio: CGFloat(ratio)) else {
            throw ControlError(
                code: .notFound,
                message: "no \(axis.rawValue) split around that pane to resize",
                action: "the pane must sit inside a matching-axis split"
            )
        }
        appState.saveWorkspaces()
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    #if DEBUG
    /// DEBUG-ONLY (#167): drive a single in-place `set_size` on the pane's
    /// surface, bypassing SwiftUI layout, so a resize/reflow transition can be
    /// reproduced in isolation. Compiled out of Release entirely — the dispatch
    /// case is `#if DEBUG` too, so a Release app answers `pane.resize` with
    /// `unknown_command`.
    private func paneResize(_ args: ControlArgs) throws -> ControlData {
        guard let cols = args.cols, let rows = args.rows, cols >= 1, rows >= 1 else {
            throw ControlError(code: .badRequest, message: "pane.resize requires cols and rows ≥ 1")
        }
        let (_, workspace) = try resolveWorkspace(args)
        let target = try resolvePane(args, in: workspace)
        guard let view = target.pane.nsView, view.debugResizeSurface(cols: cols, rows: rows) else {
            throw ControlError(
                code: .noSurface,
                message: "the pane's terminal isn't live yet (or its cell size is unknown)",
                action: "select its tab once so the surface spawns, then retry"
            )
        }
        return ControlData(panes: [paneInfo(target.pane, in: target.tab, workspace: workspace)])
    }

    /// DEBUG-ONLY (#227): drive `TerminalTab.movePane(to:)` — the grab-handle
    /// drag-and-drop reshape — headlessly, so reorders can be reproduced and
    /// regression-tested without a mouse. `dest` targets a pane in the same
    /// tab (a local `.pane` drop); omitting it moves to the workspace edge on
    /// the `zone` side (a `.rootEdge` drop).
    private func paneMove(_ args: ControlArgs) throws -> ControlData {
        let zone: PaneDropZone
        switch args.zone {
        case "left": zone = .left
        case "right": zone = .right
        case "top": zone = .top
        case "bottom": zone = .bottom
        default:
            throw ControlError(code: .badRequest, message: "pane.move requires a zone: left, right, top, or bottom")
        }
        let (_, workspace) = try resolveWorkspace(args)
        let source = try resolvePane(args, in: workspace)
        let target: TabDropResolution.Target
        if let destSelector = args.dest, !destSelector.isEmpty {
            var destArgs = args
            destArgs.pane = destSelector
            destArgs.session = nil
            let dest = try resolvePane(destArgs, in: workspace)
            guard dest.tab === source.tab else {
                throw ControlError(code: .badRequest, message: "destination pane must be in the same tab")
            }
            target = .pane(dest.pane.id, zone)
        } else {
            target = .rootEdge(zone)
        }
        guard source.tab.movePane(source.pane.id, to: target) else {
            throw ControlError(
                code: .badRequest,
                message: "move failed: self-target, or the pane is the tab's only one"
            )
        }
        appState.saveWorkspaces()
        return ControlData(panes: [paneInfo(source.pane, in: source.tab, workspace: workspace)])
    }

    /// DEBUG-ONLY (#227): drive `AppState.mergeTab(at:)` — the sidebar
    /// tab-into-workspace drop — headlessly. The source tab (`tab` selector)
    /// merges into the project's ACTIVE tab at the resolved target: beside
    /// `dest` (a pane in the active tab) or at the workspace edge.
    private func tabMerge(_ args: ControlArgs) throws -> ControlData {
        let zone: PaneDropZone
        switch args.zone {
        case "left": zone = .left
        case "right": zone = .right
        case "top": zone = .top
        case "bottom": zone = .bottom
        default:
            throw ControlError(code: .badRequest, message: "tab.merge requires a zone: left, right, top, or bottom")
        }
        let (project, workspace) = try resolveWorkspace(args)
        let (_, sourceTab) = try resolveTab(args, in: workspace)
        let target: TabDropResolution.Target
        if let destSelector = args.dest, !destSelector.isEmpty {
            var destArgs = args
            destArgs.pane = destSelector
            destArgs.session = nil
            destArgs.tab = nil
            let dest = try resolvePane(destArgs, in: workspace)
            target = .pane(dest.pane.id, zone)
        } else {
            target = .rootEdge(zone)
        }
        appState.mergeTab(sourceTab.id, from: project.id, at: target, inProject: project.id)
        guard let active = workspace.activeTab else {
            throw ControlError(code: .notFound, message: "no active tab after merge")
        }
        return ControlData(panes: active.splitRoot.allPanes().map { paneInfo($0, in: active, workspace: workspace) })
    }
    #endif

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
        try rejectPinned(project, verb: "layout apply")
        if let error = appState.applyLayout(project: project) {
            throw ControlError(code: .notFound, message: error.localizedDescription)
        }
        // A destructive reconcile is staged for UI confirmation; headless
        // callers either force it through or get a typed `busy` — the staged
        // dialog must never dangle waiting for a click that won't come.
        if appState.pendingLayoutApply != nil {
            if args.force == true {
                // Raises its own toast.
                appState.confirmPendingLayoutApply()
            } else {
                appState.cancelPendingLayoutApply()
                throw ControlError(
                    code: .busy,
                    message: "applying would close panes and end their processes",
                    action: "re-run with --force to apply anyway"
                )
            }
        } else {
            // Non-destructive path applied immediately. The window is on screen
            // and its panes just changed, so confirm it the same way the
            // palette command does — `layout save` already toasts, and the two
            // verbs shouldn't disagree about whether a CLI apply is visible.
            appState.presentToast("Layout applied")
        }
        return ControlData()
    }

    private func layoutSave(_ args: ControlArgs) throws -> ControlData {
        let project = try resolveProject(args.project)
        try rejectPinned(project, verb: "layout save")
        if let error = appState.saveLayout(project: project, siblingProjects: projectStore.projects) {
            throw ControlError(code: .internalError, message: error.localizedDescription)
        }
        return ControlData()
    }

    /// The layout verbs must never treat the SYNTHETIC pinned project as a
    /// real one: `layout save` would write a project file declaring the home
    /// directory (which first-open auto-apply would then pick up for any
    /// home-rooted project), and `layout apply --force` would swap the pinned
    /// workspace's tabs out from under the records.
    private func rejectPinned(_ project: Project, verb: String) throws {
        guard project.id == PinnedTabs.projectID else { return }
        throw ControlError(
            code: .badRequest,
            message: "\(verb) doesn't apply to the pinned workspace — its layout is managed automatically",
            action: "edit ~/.config/macterm/projects/pinned.yaml instead"
        )
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
            // The pinned workspace resolves through its synthetic project so
            // tab/pane verbs keep working while it's active.
            if appState.activeProjectID == PinnedTabs.projectID {
                return PinnedTabs.project
            }
            guard let active = projectStore.projects.first(where: { $0.id == appState.activeProjectID }) else {
                throw ControlError(
                    code: .notFound,
                    message: "no active project",
                    action: "pass --project or select one in the app"
                )
            }
            return active
        }
        // `--project pinned` (or the sentinel UUID) targets the pinned
        // workspace. Checked before the name lookup so a user project that
        // happens to be named "pinned" is still reachable by UUID/index.
        if selector.lowercased() == PinnedTabs.displayName.lowercased()
            || selector == PinnedTabs.projectID.uuidString
        {
            return PinnedTabs.project
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
        if text.hasPrefix("\(prefix):") {
            text = text.dropFirst(prefix.count + 1)
        }
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
                    if let pane = tab.splitRoot.findPane(id: id) {
                        return (tab, pane)
                    }
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
            focused: tab.id == workspace.activeTabID && pane.id == tab.focusedPaneID,
            state: controlState(for: pane.executionState)
        )
    }

    /// Wire representation of `TerminalExecutionState` — a plain string keeps
    /// the protocol's JSON stable even if the enum's cases are renamed.
    private func controlState(for state: TerminalExecutionState) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .done: "done"
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
