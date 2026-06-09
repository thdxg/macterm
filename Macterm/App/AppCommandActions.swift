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
        case .renameProject:
            guard let current else { return nil }
            let projectID = current.id
            return {
                ctx.appState.sidebarVisible = true
                // See .renameTab: defer so the sidebar row exists first.
                DispatchQueue.main.async { ctx.appState.renamingProjectID = projectID }
            }
        case .removeProject:
            guard let projectID else { return nil }
            return {
                ctx.appState.removeProject(projectID)
                ctx.projectStore.remove(id: projectID)
            }
        case .replaceProjectPathWithCurrentDir:
            guard let projectID,
                  let pane = ctx.appState.focusedPane(for: projectID),
                  let pwd = pane.nsView?.currentPwd, !pwd.isEmpty,
                  current?.path != pwd
            else { return nil }
            return { ctx.appState.replaceProjectPathWithCurrentDir(projectStore: ctx.projectStore) }
        case .applyLayout:
            guard let projectID, let current else { return nil }
            return {
                if let error = ctx.appState.applyLayout(projectID: projectID, projectName: current.name, projectRoot: current.path) {
                    presentLayoutError(error, verb: "apply")
                }
            }
        case .saveLayout:
            guard let projectID, let current else { return nil }
            return {
                if let error = ctx.appState.saveLayout(projectID: projectID, projectName: current.name, projectRoot: current.path) {
                    presentLayoutError(error, verb: "save")
                }
            }
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
        }
    }
}

/// Surface a layout apply/save failure (most commonly a missing or unparseable
/// `.macterm/layout.yaml`) as a simple modal alert.
@MainActor
private func presentLayoutError(_ error: Error, verb: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Couldn't \(verb) layout"
    alert.informativeText = error.localizedDescription
    alert.runModal()
}
