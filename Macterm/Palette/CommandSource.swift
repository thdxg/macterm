import AppKit

/// Palette source for action commands. Iterates `AppCommand.allCases` so the
/// palette, Settings, and keyboard bindings all read from the same list.
/// Titles come from `AppCommand.title` (sentence case); keybind overlays
/// come from the associated `HotkeyAction` when the command is bindable.
@MainActor
struct CommandSource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        allItems(context).compactMap { item in
            guard let score = fuzzyScore(query: query, target: item.title) else { return nil }
            return PaletteItem(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                category: item.category,
                keybind: item.keybind,
                score: score,
                action: item.action
            )
        }
    }

    func emptyItems(context: PaletteContext) -> [PaletteItem]? {
        allItems(context)
    }

    // MARK: - Composition

    private func allItems(_ ctx: PaletteContext) -> [PaletteItem] {
        AppCommand.allCases.compactMap { make(command: $0, ctx: ctx) }
    }

    /// Builds a PaletteItem for `command`, or returns nil when the command
    /// doesn't apply in the current context (e.g. tab/pane commands when no
    /// project is active, rename/remove when there's no current project).
    private func make(command: AppCommand, ctx: PaletteContext) -> PaletteItem? {
        let projectID = ctx.appState.activeProjectID
        let current = projectID.flatMap { id in ctx.projectStore.projects.first(where: { $0.id == id }) }

        let action: (() -> Void)?
        switch command {
        // Tabs / panes — require an active project.
        case .newTab:
            guard let projectID else { return nil }
            action = { ctx.appState.createTab(projectID: projectID, projects: ctx.projectStore.projects) }
        case .closePane:
            guard let projectID else { return nil }
            action = {
                if let pane = ctx.appState.focusedPane(for: projectID) {
                    ctx.appState.requestClosePane(pane.id, projectID: projectID)
                }
            }
        case .nextTab:
            action = { ctx.appState.selectGlobalTab(.next, projects: ctx.projectStore.projects) }
        case .previousTab:
            action = { ctx.appState.selectGlobalTab(.previous, projects: ctx.projectStore.projects) }
        case .recentTab:
            guard let projectID else { return nil }
            action = { ctx.appState.cycleRecentTab(projectID: projectID) }
        case .splitRight:
            guard let projectID else { return nil }
            action = { ctx.appState.splitPane(direction: .horizontal, projectID: projectID) }
        case .splitDown:
            guard let projectID else { return nil }
            action = { ctx.appState.splitPane(direction: .vertical, projectID: projectID) }
        case .focusLeft:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.left, projectID: projectID) }
        case .focusRight:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.right, projectID: projectID) }
        case .focusUp:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.up, projectID: projectID) }
        case .focusDown:
            guard let projectID else { return nil }
            action = { ctx.appState.focusPaneInDirection(.down, projectID: projectID) }
        case .resizeLeft:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.left, projectID: projectID) }
        case .resizeRight:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.right, projectID: projectID) }
        case .resizeUp:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.up, projectID: projectID) }
        case .resizeDown:
            guard let projectID else { return nil }
            action = { ctx.appState.resizePane(.down, projectID: projectID) }
        // Projects.
        case .openProject:
            action = { _ = ctx.appState.openProject(store: ctx.projectStore) }
        case .renameProject:
            guard let current else { return nil }
            action = { promptRename(project: current, store: ctx.projectStore) }
        case .removeProject:
            guard let projectID else { return nil }
            action = {
                ctx.appState.removeProject(projectID)
                ctx.projectStore.remove(id: projectID)
            }
        case .nextProject:
            action = { ctx.appState.selectNextProject(projects: ctx.projectStore.projects) }
        case .previousProject:
            action = { ctx.appState.selectPreviousProject(projects: ctx.projectStore.projects) }
        // Window.
        case .toggleSidebar:
            action = { ctx.appState.sidebarVisible.toggle() }
        case .closeWindow:
            action = { (NSApp.delegate as? AppDelegate)?.mainWindow?.orderOut(nil) }
        }

        guard let action else { return nil }
        return PaletteItem(
            title: command.title,
            category: command.category.rawValue,
            keybind: command.hotkeyAction.flatMap(keybindDisplay),
            score: 0,
            action: action
        )
    }

    private func keybindDisplay(_ action: HotkeyAction) -> String? {
        let raw = HotkeyRegistry.selectedShortcutString(for: action)
        let display = HotkeyRegistry.displayString(for: raw)
        return display == "Disabled" ? nil : display
    }

    /// Shows a simple NSAlert with a text field prompting for a new project
    /// name. Commits only if the user confirms and the trimmed value is
    /// non-empty and different from the current name.
    private func promptRename(project: Project, store: ProjectStore) {
        let alert = NSAlert()
        alert.messageText = "Rename project"
        alert.informativeText = "Enter a new name for \"\(project.name)\"."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = project.name
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != project.name else { return }
        store.rename(id: project.id, to: newName)
    }
}
