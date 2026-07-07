import AppKit

/// Inputs every `AppCommand` needs to do its work. The palette wraps its own
/// `PaletteContext` into this; menu items build it directly.
@MainActor
struct AppCommandContext {
    let appState: AppState
    let projectStore: ProjectStore
}

extension AppCommand {
    /// Returns the closure that performs this command, or nil if the command
    /// doesn't apply in the current context (e.g. tab/pane commands when no
    /// project is active, "Replace path" when the pane's pwd matches the
    /// project's). Single source of truth for execution — used by both the
    /// command palette and the menu bar so the two stay in sync.
    @MainActor
    func action(in ctx: AppCommandContext) -> (@MainActor () -> Void)? {
        let projectID = ctx.appState.activeProjectID
        let current = projectID.flatMap { id in ctx.projectStore.projects.first(where: { $0.id == id }) }

        switch self {
        case .newTab:
            guard let projectID else { return nil }
            return { ctx.appState.createTab(projectID: projectID, projects: ctx.projectStore.projects) }
        case .closePane:
            guard let projectID else { return nil }
            return {
                if let pane = ctx.appState.focusedPane(for: projectID) {
                    ctx.appState.requestClosePane(pane.id, projectID: projectID)
                }
            }
        case .nextTab:
            return { ctx.appState.selectGlobalTab(.next, projects: ctx.projectStore.projects) }
        case .previousTab:
            return { ctx.appState.selectGlobalTab(.previous, projects: ctx.projectStore.projects) }
        case .recentTab:
            guard let projectID else { return nil }
            return { ctx.appState.cycleRecentTab(projectID: projectID) }
        case .previousTabInProject:
            guard let projectID else { return nil }
            return { ctx.appState.selectPreviousTab(projectID: projectID) }
        case .nextTabInProject:
            guard let projectID else { return nil }
            return { ctx.appState.selectNextTab(projectID: projectID) }
        case .moveTabUp:
            guard let projectID else { return nil }
            return { ctx.appState.moveActiveTab(by: -1, projectID: projectID) }
        case .moveTabDown:
            guard let projectID else { return nil }
            return { ctx.appState.moveActiveTab(by: 1, projectID: projectID) }
        case .focusSidebar:
            return { ctx.appState.enterSidebarFocus() }
        case .renameTab:
            guard let projectID,
                  let tab = ctx.appState.workspaces[projectID]?.activeTab
            else { return nil }
            let tabID = tab.id
            return {
                ctx.appState.sidebarVisible = true
                // Defer a tick so the sidebar (and its row's TextField) is in
                // the hierarchy before we ask it to begin editing — otherwise,
                // when the sidebar was collapsed, the field can't take first
                // responder. Applies to every caller (palette, menu, hotkey).
                DispatchQueue.main.async { ctx.appState.renamingTabID = tabID }
            }
        case .splitRight:
            guard let projectID else { return nil }
            return { ctx.appState.splitPane(direction: .horizontal, projectID: projectID) }
        case .splitDown:
            guard let projectID else { return nil }
            return { ctx.appState.splitPane(direction: .vertical, projectID: projectID) }
        case .splitAuto:
            guard let projectID else { return nil }
            return { ctx.appState.autoSplitPane(projectID: projectID) }
        case .zoomPane:
            guard let projectID else { return nil }
            return { ctx.appState.toggleZoom(projectID: projectID) }
        case .focusLeft:
            guard let projectID else { return nil }
            return { ctx.appState.focusPaneInDirection(.left, projectID: projectID) }
        case .focusRight:
            guard let projectID else { return nil }
            return { ctx.appState.focusPaneInDirection(.right, projectID: projectID) }
        case .focusUp:
            guard let projectID else { return nil }
            return { ctx.appState.focusPaneInDirection(.up, projectID: projectID) }
        case .focusDown:
            guard let projectID else { return nil }
            return { ctx.appState.focusPaneInDirection(.down, projectID: projectID) }
        case .nextPane:
            guard let projectID else { return nil }
            return { ctx.appState.cyclePane(forward: true, projectID: projectID) }
        case .previousPane:
            guard let projectID else { return nil }
            return { ctx.appState.cyclePane(forward: false, projectID: projectID) }
        case .resizeLeft:
            guard let projectID else { return nil }
            return { ctx.appState.resizePane(.left, projectID: projectID) }
        case .resizeRight:
            guard let projectID else { return nil }
            return { ctx.appState.resizePane(.right, projectID: projectID) }
        case .resizeUp:
            guard let projectID else { return nil }
            return { ctx.appState.resizePane(.up, projectID: projectID) }
        case .resizeDown:
            guard let projectID else { return nil }
            return { ctx.appState.resizePane(.down, projectID: projectID) }
        case .openProject:
            return { _ = ctx.appState.openProject(store: ctx.projectStore) }
        case .newRemoteProject:
            return { ctx.appState.isNewRemoteProjectSheetPresented = true }
        case .renameProject:
            guard let current else { return nil }
            let projectID = current.id
            return {
                ctx.appState.sidebarVisible = true
                // See .renameTab: defer so the sidebar row exists first.
                DispatchQueue.main.async { ctx.appState.renamingProjectID = projectID }
            }
        case .unloadProject:
            guard let projectID, ctx.appState.isProjectLoaded(projectID) else { return nil }
            return { ctx.appState.requestUnloadProject(projectID) }
        case .removeProject:
            guard let projectID else { return nil }
            return {
                ctx.appState.requestRemoveProject(projectID) {
                    ctx.appState.removeProject(projectID)
                    ctx.projectStore.remove(id: projectID)
                }
            }
        case .replaceProjectPathWithCurrentDir:
            // Remote projects (#104): OSC 7 reports a directory on the REMOTE
            // host — writing it into `Project.path` would corrupt the
            // project's identity into a local-looking path.
            guard let current, !current.isRemote,
                  let pane = ctx.appState.focusedPane(for: current.id),
                  let pwd = pane.nsView?.currentPwd, !pwd.isEmpty,
                  current.path != pwd
            else { return nil }
            return { ctx.appState.replaceProjectPathWithCurrentDir(projectStore: ctx.projectStore) }
        case .applyLayout:
            // Requires an applicable central file. `.invalid` stays enabled on
            // purpose: invoking it surfaces the parse-error dialog instead of
            // failing silently. `.none`/`.emptyTabs` disable the menu item and
            // mute the palette row (see `paletteDisabledHint`) — except that a
            // committed legacy `.macterm/layout.yaml` keeps `.none` enabled:
            // invoking it imports the file into the central directory, then
            // applies (deprecated seed, #114 — an existing project's snapshot
            // suppresses the first-open import, so this is its only way in).
            guard let current else { return nil }
            switch ctx.appState.projectFiles.applyState(forProjectPath: current.path) {
            case .applicable,
                 .invalid:
                return { ctx.appState.applyLayoutPresentingError(current) }
            case .none:
                guard LayoutFile.exists(atProjectRoot: current.path) else { return nil }
                return { ctx.appState.applyLayoutPresentingError(current) }
            case .emptyTabs:
                return nil
            }
        case .saveLayout:
            guard let current else { return nil }
            return { ctx.appState.saveLayoutPresentingError(current) }
        case .nextProject:
            return { ctx.appState.selectNextProject(projects: ctx.projectStore.projects) }
        case .previousProject:
            return { ctx.appState.selectPreviousProject(projects: ctx.projectStore.projects) }
        case .toggleSidebar:
            return { ctx.appState.sidebarVisible.toggle() }
        case .closeWindow:
            return { (NSApp.delegate as? AppDelegate)?.mainWindow?.orderOut(nil) }
        case .toggleCommandPalette:
            return { ctx.appState.isCommandPaletteVisible.toggle() }
        case .reloadGhosttyConfig:
            return { GhosttyApp.shared.reloadAndReport() }
        case .toggleQuickTerminal:
            return { QuickTerminalService.shared.toggle() }
        case .checkForUpdate:
            // Always present in the palette; the guard only no-ops when a check
            // is already in flight (canCheckForUpdates flips false during one).
            return {
                guard Updater.shared.canCheckForUpdates else { return }
                Updater.shared.checkForUpdates()
            }
        }
    }

    /// Why this command shows muted-but-visible in the palette, or nil when it
    /// should follow the default rule (hidden when `action(in:)` is nil).
    /// Only "Apply Layout" opts in: a missing or tab-less project file is a
    /// state worth *seeing* in the palette — hiding the command entirely would
    /// read as a bug, and the hint says what's missing. The menu bar item
    /// keeps the plain disabled look either way.
    @MainActor
    func paletteDisabledHint(in ctx: AppCommandContext) -> String? {
        guard self == .applyLayout,
              let projectID = ctx.appState.activeProjectID,
              let current = ctx.projectStore.projects.first(where: { $0.id == projectID })
        else { return nil }
        switch ctx.appState.projectFiles.applyState(forProjectPath: current.path) {
        case .none:
            // A legacy `.macterm/layout.yaml` keeps the command enabled
            // (import-then-apply), so no hint for it.
            guard !LayoutFile.exists(atProjectRoot: current.path) else { return nil }
            return "No project file for this project — use “Save Layout” to create one"
        case .emptyTabs:
            return "The project file declares no tabs"
        case .applicable,
             .invalid:
            return nil
        }
    }

    /// Secondary line for an *enabled* palette row. Only "Apply Layout" uses
    /// it: when duplicate files declare the active project's path, filename
    /// order silently picks one — say which, so a hand-authored duplicate
    /// doesn't read as "my edits don't apply".
    @MainActor
    func paletteSubtitle(in ctx: AppCommandContext) -> String? {
        guard self == .applyLayout,
              let projectID = ctx.appState.activeProjectID,
              let current = ctx.projectStore.projects.first(where: { $0.id == projectID })
        else { return nil }
        let matches = ctx.appState.projectFiles.matches(forProjectPath: current.path)
        guard matches.count > 1 else { return nil }
        let ignored = matches.dropFirst().map(\.url.lastPathComponent).joined(separator: ", ")
        return "Using \(matches[0].url.lastPathComponent) — ignoring duplicate \(ignored)"
    }
}
