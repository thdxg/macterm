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
            // Carry every field forward (notably `isEnabled`) so a disabled
            // hint row stays muted/unselectable when it matches a search — a
            // hand-copied initializer would silently reset it to the default.
            return item.with(score: score)
        }
    }

    func emptyItems(context: PaletteContext) -> [PaletteItem]? {
        allItems(context)
    }

    // MARK: - Composition

    private func allItems(_ ctx: PaletteContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        var customAdded = false
        for command in AppCommand.allCases {
            // The custom palettes join the Palettes section right after the
            // built-in screens, before the first command of another kind.
            if !customAdded, command.category != .palettes {
                items += customPaletteItems(ctx)
                customAdded = true
            }
            if let item = make(command: command, ctx: ctx) { items.append(item) }
        }
        if !customAdded { items += customPaletteItems(ctx) }
        return items
    }

    /// One row per custom palette file (`CustomPaletteStore`): a way into
    /// its root. A file that couldn't be read keeps a normal row, named as
    /// far as its YAML parses, with a warning glyph before the chevron;
    /// entering it shows the error — so a typo in the YAML is found where
    /// the palette was expected rather than nowhere. A palette turned off in
    /// Settings is hidden, as a built-in screen is.
    private func customPaletteItems(_ ctx: PaletteContext) -> [PaletteItem] {
        let store = ctx.appState.customPalettes
        return store.entries.compactMap { entry in
            guard Preferences.shared.isPaletteEnabled(entry.settingsID), let target = store.rootTarget(id: entry.id) else { return nil }
            let chord = PaletteHotkeys.shared.selectedShortcutString(paletteID: entry.id)
            let symbols = HotkeyRegistry.displaySymbols(for: chord)
            return PaletteItem(
                id: "palette:\(entry.id)",
                title: entry.pill.title,
                subtitle: entry.description,
                category: AppCommand.Category.palettes.rawValue,
                keybind: symbols.isEmpty ? nil : HotkeyRegistry.displayString(for: chord),
                keybindSymbols: symbols.isEmpty ? nil : symbols,
                score: 0,
                opensScope: .custom(target),
                warning: entry.failure?.localizedDescription,
                action: {}
            )
        }
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
            // A command that is a palette screen opens it in place rather
            // than closing the palette to reopen it.
            opensScope: command.paletteScope,
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
