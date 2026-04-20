import AppKit

/// Palette source for action commands — new tab, split, close, focus/resize,
/// project, window. Items are the same in empty-state and active-search
/// (the engine filters by score in the latter).
@MainActor
struct CommandSource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        allCommands(context).compactMap { item in
            guard let score = fuzzyScore(query: query, target: item.title) else { return nil }
            // Rebuild with the score populated; rest of the metadata is copied.
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
        allCommands(context)
    }

    // MARK: - Composition

    private func allCommands(_ ctx: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let projectID = ctx.appState.activeProjectID {
            items += tabCommands(projectID: projectID, ctx: ctx)
            items += paneCommands(projectID: projectID, ctx: ctx)
        }
        items += projectCommands(ctx: ctx)
        items += windowCommands(ctx: ctx)
        return items
    }

    private func tabCommands(projectID: UUID, ctx: PaletteContext) -> [PaletteItem] {
        [
            command("New Tab", category: "Tabs", action: .newTab) {
                ctx.appState.createTab(projectID: projectID)
            },
            command("Close Pane", category: "Tabs", action: .closePane) {
                if let pane = ctx.appState.focusedPane(for: projectID) {
                    ctx.appState.requestClosePane(pane.id, projectID: projectID)
                }
            },
            command("Next Tab", category: "Tabs", action: .nextGlobalTab) {
                ctx.appState.selectGlobalTab(.next, projects: ctx.projectStore.projects)
            },
            command("Previous Tab", category: "Tabs", action: .previousGlobalTab) {
                ctx.appState.selectGlobalTab(.previous, projects: ctx.projectStore.projects)
            },
        ]
    }

    private func paneCommands(projectID: UUID, ctx: PaletteContext) -> [PaletteItem] {
        [
            command("Split Right", category: "Panes", action: .splitRight) {
                ctx.appState.splitPane(direction: .horizontal, projectID: projectID)
            },
            command("Split Down", category: "Panes", action: .splitDown) {
                ctx.appState.splitPane(direction: .vertical, projectID: projectID)
            },
            command("Focus Left", category: "Panes", action: .focusPaneLeft) {
                ctx.appState.focusPaneInDirection(.left, projectID: projectID)
            },
            command("Focus Right", category: "Panes", action: .focusPaneRight) {
                ctx.appState.focusPaneInDirection(.right, projectID: projectID)
            },
            command("Focus Up", category: "Panes", action: .focusPaneUp) {
                ctx.appState.focusPaneInDirection(.up, projectID: projectID)
            },
            command("Focus Down", category: "Panes", action: .focusPaneDown) {
                ctx.appState.focusPaneInDirection(.down, projectID: projectID)
            },
            command("Resize Pane Left", category: "Panes", action: .resizePaneLeft) {
                ctx.appState.resizePane(.left, projectID: projectID)
            },
            command("Resize Pane Right", category: "Panes", action: .resizePaneRight) {
                ctx.appState.resizePane(.right, projectID: projectID)
            },
            command("Resize Pane Up", category: "Panes", action: .resizePaneUp) {
                ctx.appState.resizePane(.up, projectID: projectID)
            },
            command("Resize Pane Down", category: "Panes", action: .resizePaneDown) {
                ctx.appState.resizePane(.down, projectID: projectID)
            },
        ]
    }

    private func projectCommands(ctx: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = [
            command("Open Project", category: "Projects", action: .openProject) {
                _ = ctx.appState.openProject(store: ctx.projectStore)
            },
        ]
        if let projectID = ctx.appState.activeProjectID {
            items.append(command("Remove Project", category: "Projects", action: nil) {
                ctx.appState.removeProject(projectID)
                ctx.projectStore.remove(id: projectID)
            })
        }
        return items
    }

    private func windowCommands(ctx: PaletteContext) -> [PaletteItem] {
        [
            command("Toggle Sidebar", category: "Window", action: .toggleSidebar) {
                ctx.appState.sidebarVisible.toggle()
            },
            command("Close Window", category: "Window", action: .closeWindow) {
                (NSApp.delegate as? AppDelegate)?.mainWindow?.orderOut(nil)
            },
        ]
    }

    private func command(
        _ title: String,
        category: String,
        action: HotkeyAction?,
        perform: @escaping () -> Void
    ) -> PaletteItem {
        PaletteItem(
            title: title,
            category: category,
            keybind: action.flatMap(keybindDisplay),
            score: 0,
            action: perform
        )
    }

    private func keybindDisplay(_ action: HotkeyAction) -> String? {
        let raw = HotkeyRegistry.selectedShortcutString(for: action)
        let display = HotkeyRegistry.displayString(for: raw)
        return display == "Disabled" ? nil : display
    }
}
