import AppKit

/// The palette's Password Manager: every saved password, searchable by
/// command or prompt, typed into the focused pane when picked
/// (`PasswordPromptMonitor.fillOnDemand`), plus ways to add one.
///
/// Empty, it lists Add Password… and then every entry. Searching puts the
/// matching entries first and offers to add a password with the text typed
/// as its command (an entry always has one; see `PasswordEditorSheet`).
@MainActor
struct PasswordPaletteScope: PaletteScope {
    var vault: PasswordVault = .shared

    let pill = PalettePill(title: "Password Manager", systemImage: "key.fill")
    let placeholder = "Search by command or prompt..."

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        let canFill = Self.targetPane(context.appState) != nil
        guard !query.isEmpty else {
            var sections = [PaletteSection(header: nil, items: [
                addItem(id: "password-add", title: "Add Password…", request: .new(), context: context),
            ])]
            if !vault.entries.isEmpty {
                let items = vault.entries.map { item(for: $0, score: 0, canFill: canFill, context: context) }
                sections.append(PaletteSection(header: "Saved Passwords", items: items))
            }
            return sections
        }

        let text = query.trimmed
        let search = SearchQuery(text)
        let matches = vault.entries.compactMap { entry -> PaletteItem? in
            guard let match = Search.match(search, fields: Self.fields(entry.id)) else { return nil }
            return item(for: entry, score: 0, canFill: canFill, context: context).with(match)
        }
        .sorted { ($0.score, $0.title, $0.id) < ($1.score, $1.title, $1.id) }

        var sections: [PaletteSection] = []
        if !matches.isEmpty {
            sections.append(PaletteSection(header: "Saved Passwords", items: matches))
        }
        sections.append(PaletteSection(header: "Add", items: [
            addItem(
                id: "password-add-command",
                title: "Add Password for Command: \(text)",
                request: .new(command: text),
                context: context
            ),
        ]))
        return sections
    }

    /// What an entry is found by: its title (as shown), the full command,
    /// and the prompt.
    static func fields(_ id: PasswordEntryID) -> [String] {
        [id.title, id.command, id.isOnDemandOnly ? nil : id.prompt].compactMap(\.self)
    }

    /// The pane a picked password is typed into: the focused pane of the
    /// active tab in the window the user is in.
    static func targetPane(_ appState: AppState) -> Pane? {
        appState.activeProjectID.flatMap { appState.focusedPane(for: $0) }
    }

    private func item(for entry: SavedPassword, score: Int, canFill: Bool, context: PaletteContext) -> PaletteItem {
        let subtitle: String? = if !canFill {
            "No terminal pane to type into"
        } else if entry.id.isOnDemandOnly {
            nil
        } else if entry.id.command == nil {
            "\(entry.id.prompt) — any command"
        } else {
            entry.id.prompt
        }
        return PaletteItem(
            id: "password:\(entry.id.account)",
            title: entry.id.title,
            subtitle: subtitle,
            score: score,
            isEnabled: canFill
        ) { [appState = context.appState] in
            // After the palette has closed and focus is back in the pane, so
            // the confirmation and Touch ID come up over the terminal.
            appState.postPaletteAction = {
                appState.restoreFocusToActivePane()
                guard let pane = Self.targetPane(appState) else {
                    NSSound.beep()
                    return
                }
                PasswordPromptMonitor.shared.fillOnDemand(entry.id, in: pane)
            }
        }
    }

    private func addItem(
        id: String,
        title: String,
        request: PasswordEditorRequest,
        context: PaletteContext
    ) -> PaletteItem {
        PaletteItem(id: id, title: title, score: 0) { [appState = context.appState] in
            appState.postPaletteAction = { appState.presentPasswordEditor(request) }
        }
    }
}
