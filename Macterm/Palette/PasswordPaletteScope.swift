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
        let matches = vault.entries.compactMap { entry -> PaletteItem? in
            guard let score = Self.score(entry.id, query: text) else { return nil }
            return item(for: entry, score: score, canFill: canFill, context: context)
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

    /// Best match over what the entry is shown as and what it is filed
    /// under: the shortened command, the full one, and the prompt.
    static func score(_ id: PasswordEntryID, query: String) -> Int? {
        [id.displayCommand, id.command, id.isOnDemandOnly ? nil : id.prompt]
            .compactMap(\.self)
            .compactMap { fuzzyScore(query: query, target: $0) }
            .min()
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
