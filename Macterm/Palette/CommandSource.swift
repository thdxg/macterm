import AppKit

/// Palette source for action commands. Iterates `AppCommand.allCases` so the
/// palette, Settings, and keyboard bindings all read from the same list.
/// Titles come from `AppCommand.title` (Title Case); keybind overlays
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
                keybindSymbols: item.keybindSymbols,
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
        // The palette has to be open to see itself; hide the entry.
        if command == .toggleCommandPalette { return nil }

        let commandCtx = AppCommandContext(appState: ctx.appState, projectStore: ctx.projectStore)
        guard let rawAction = command.action(in: commandCtx) else {
            // Most inapplicable commands hide; a few explain themselves as a
            // muted row instead (e.g. "Apply Layout" with no project file).
            guard let hint = command.paletteDisabledHint(in: commandCtx) else { return nil }
            return PaletteItem(
                title: command.title,
                subtitle: hint,
                category: command.category.rawValue,
                score: 0,
                isEnabled: false,
                action: {}
            )
        }

        // Rename actions need to wait until the palette has dismissed so the
        // textfield in the sidebar can take first responder. Defer via
        // postPaletteAction; CommandPaletteOverlay fires it on close.
        let action: () -> Void = switch command {
        case .renameTab,
             .renameProject:
            { ctx.appState.postPaletteAction = rawAction }
        default:
            rawAction
        }

        return PaletteItem(
            title: command.title,
            subtitle: command.paletteSubtitle(in: commandCtx),
            category: command.category.rawValue,
            keybind: command.hotkeyAction.flatMap(keybindDisplay),
            keybindSymbols: command.hotkeyAction.flatMap(keybindSymbols),
            score: 0,
            action: action
        )
    }

    private func keybindDisplay(_ action: HotkeyAction) -> String? {
        let raw = HotkeyRegistry.selectedShortcutString(for: action)
        let display = HotkeyRegistry.displayString(for: raw)
        return (display == "Disabled" || display == "None") ? nil : display
    }

    private func keybindSymbols(_ action: HotkeyAction) -> [String]? {
        let raw = HotkeyRegistry.selectedShortcutString(for: action)
        let symbols = HotkeyRegistry.displaySymbols(for: raw)
        return symbols.isEmpty ? nil : symbols
    }
}
