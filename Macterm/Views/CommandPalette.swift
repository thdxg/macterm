import AppKit
import SwiftUI

// MARK: - Model

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String?
    let keybind: String?
    let action: () -> Void

    init(title: String, subtitle: String? = nil, category: String? = nil, keybind: String? = nil, action: @escaping () -> Void) {
        id = [category ?? "", title].joined(separator: "/")
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keybind = keybind
        self.action = action
    }
}

// MARK: - Fuzzy matching

private func fuzzyMatch(query: String, target: String) -> Bool {
    guard !query.isEmpty else { return true }
    let q = query.lowercased()
    let t = target.lowercased()
    if t.contains(q) { return true }
    // Subsequence match
    var qi = q.startIndex
    for ch in t where ch == q[qi] {
        qi = q.index(after: qi)
        if qi == q.endIndex { return true }
    }
    return false
}

private func fuzzyScore(query: String, target: String) -> Int {
    let q = query.lowercased()
    let t = target.lowercased()
    if t.hasPrefix(q) { return 0 }
    if t.contains(q) { return 1 }
    return 2
}

// MARK: - View

struct CommandPaletteOverlay: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    var body: some View {
        if appState.isCommandPaletteVisible {
            ZStack {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture { appState.isCommandPaletteVisible = false }

                VStack {
                    CommandPalettePanel()
                        .frame(width: 500)
                        .padding(.top, 80)
                    Spacer()
                }
            }
            .transition(.opacity)
        }
    }
}

private struct CommandPalettePanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var query = ""
    @State
    private var selectedIndex = 0
    @State
    private var cachedItems: [CommandPaletteItem] = []
    @State
    private var cachedSections: [Section] = []
    @FocusState
    private var isFieldFocused: Bool

    private var searchQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private func computeItems() -> [CommandPaletteItem] {
        // Path-like queries are handled separately — only show matching
        // directories so users can open them as projects.
        if looksLikePath(searchQuery) {
            return directoryCompletions
        }
        if searchQuery.isEmpty {
            return recentProjectItems + commandItems
        }
        // Rank projects slightly higher than commands. The ranking constant is
        // additive to the fuzzy score so a strong command match can still beat
        // a weak project match.
        let projectMatches = projectItems
            .compactMap { item -> (CommandPaletteItem, Int)? in
                let titleScore = fuzzyScore(query: searchQuery, target: item.title)
                let subtitleScore = item.subtitle.map { fuzzyScore(query: searchQuery, target: $0) } ?? 3
                let best = min(titleScore, subtitleScore)
                guard best < 3 else { return nil }
                return (item, best)
            }
        let commandMatches = commandItems
            .filter { fuzzyMatch(query: searchQuery, target: $0.title) }
            .map { ($0, fuzzyScore(query: searchQuery, target: $0.title) + 1) }
        let merged = (projectMatches + commandMatches).sorted { $0.1 < $1.1 }
        return merged.map(\.0)
    }

    private func looksLikePath(_ q: String) -> Bool {
        q.hasPrefix("/") || q.hasPrefix("~")
    }

    private var placeholderText: String {
        if looksLikePath(searchQuery) { return "Open directory as new project..." }
        return "Search projects or commands..."
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fgMuted)
                TextField(placeholderText, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fg)
                    .focused($isFieldFocused)
                    .onSubmit { execute() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(MactermTheme.border)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(cachedSections.enumerated()), id: \.offset) { sectionIndex, section in
                            if let category = section.category {
                                Text(category)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MactermTheme.fgDim)
                                    .padding(.horizontal, 14)
                                    .padding(.top, sectionIndex == 0 ? 8 : 12)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in
                                let idx = cachedItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                Button {
                                    selectedIndex = idx
                                    execute()
                                } label: {
                                    CommandPaletteRow(
                                        item: item,
                                        isSelected: idx == selectedIndex
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(idx)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
                .onChange(of: selectedIndex) { _, idx in
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MactermTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            query = ""
            selectedIndex = 0
            refreshItems()
            // Defer focus to the next runloop so the TextField has been created.
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
        .onChange(of: query) {
            selectedIndex = 0
            refreshItems()
        }
        .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in
            if selectedIndex < cachedItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "p"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "n"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            if selectedIndex < cachedItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            appState.isCommandPaletteVisible = false
            return .handled
        }
    }

    private func refreshItems() {
        cachedItems = computeItems()
        cachedSections = computeSections(from: cachedItems)
    }

    private func execute() {
        guard selectedIndex >= 0, selectedIndex < cachedItems.count else { return }
        appState.isCommandPaletteVisible = false
        cachedItems[selectedIndex].action()
    }

    // MARK: - Grouping

    private struct Section {
        let category: String?
        let items: [CommandPaletteItem]
    }

    private func computeSections(from list: [CommandPaletteItem]) -> [Section] {
        if looksLikePath(searchQuery) {
            return [Section(category: "Directories", items: list)]
        }
        if searchQuery.isEmpty {
            // Empty input: projects first (as a "Recent" section if any), then
            // commands grouped by their original category.
            let projects = list.filter { $0.category == "Recent" }
            let commands = list.filter { $0.category != "Recent" }
            var sections: [Section] = []
            if !projects.isEmpty { sections.append(Section(category: "Recent", items: projects)) }
            sections += groupByCategory(commands)
            return sections
        }
        // Active search: preserve the merged ranking order as one flat list so
        // the best match is always at the top regardless of origin.
        return [Section(category: nil, items: list)]
    }

    private func groupByCategory(_ list: [CommandPaletteItem]) -> [Section] {
        var seen = Set<String>()
        var order: [String] = []
        var grouped: [String: [CommandPaletteItem]] = [:]
        for item in list {
            let cat = item.category ?? ""
            if seen.insert(cat).inserted { order.append(cat) }
            grouped[cat, default: []].append(item)
        }
        return order.map { Section(category: $0.isEmpty ? nil : $0, items: grouped[$0] ?? []) }
    }

    // MARK: - Command items

    private var commandItems: [CommandPaletteItem] {
        guard let projectID = appState.activeProjectID else {
            return projectActions + windowActions
        }
        return tabActions(projectID) + paneActions(projectID) + projectActions + windowActions
    }

    private func tabActions(_ projectID: UUID) -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                title: "New Tab",
                subtitle: nil,
                category: "Tabs",
                keybind: shortcut(.newTab)
            ) { appState.createTab(projectID: projectID) },
            CommandPaletteItem(
                title: "Close Pane",
                subtitle: nil,
                category: "Tabs",
                keybind: shortcut(.closePane)
            ) {
                if let pane = appState.focusedPane(for: projectID) {
                    appState.requestClosePane(pane.id, projectID: projectID)
                }
            },
            CommandPaletteItem(
                title: "Next Tab",
                subtitle: nil,
                category: "Tabs",
                keybind: shortcut(.nextGlobalTab)
            ) {
                appState.selectGlobalTab(.next, projects: projectStore.projects)
            },
            CommandPaletteItem(
                title: "Previous Tab",
                subtitle: nil,
                category: "Tabs",
                keybind: shortcut(.previousGlobalTab)
            ) {
                appState.selectGlobalTab(.previous, projects: projectStore.projects)
            },
        ]
    }

    private func paneActions(_ projectID: UUID) -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                title: "Split Right",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.splitRight)
            ) { appState.splitPane(direction: .horizontal, projectID: projectID) },
            CommandPaletteItem(
                title: "Split Down",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.splitDown)
            ) { appState.splitPane(direction: .vertical, projectID: projectID) },
            CommandPaletteItem(
                title: "Focus Left",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.focusPaneLeft)
            ) { appState.focusPaneInDirection(.left, projectID: projectID) },
            CommandPaletteItem(
                title: "Focus Right",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.focusPaneRight)
            ) { appState.focusPaneInDirection(.right, projectID: projectID) },
            CommandPaletteItem(
                title: "Focus Up",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.focusPaneUp)
            ) { appState.focusPaneInDirection(.up, projectID: projectID) },
            CommandPaletteItem(
                title: "Focus Down",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.focusPaneDown)
            ) { appState.focusPaneInDirection(.down, projectID: projectID) },
            CommandPaletteItem(
                title: "Resize Pane Left",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.resizePaneLeft)
            ) { appState.resizePane(.left, projectID: projectID) },
            CommandPaletteItem(
                title: "Resize Pane Right",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.resizePaneRight)
            ) { appState.resizePane(.right, projectID: projectID) },
            CommandPaletteItem(
                title: "Resize Pane Up",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.resizePaneUp)
            ) { appState.resizePane(.up, projectID: projectID) },
            CommandPaletteItem(
                title: "Resize Pane Down",
                subtitle: nil,
                category: "Panes",
                keybind: shortcut(.resizePaneDown)
            ) { appState.resizePane(.down, projectID: projectID) },
        ]
    }

    private var projectActions: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                title: "Open Project",
                subtitle: nil,
                category: "Projects",
                keybind: shortcut(.openProject)
            ) { _ = appState.openProject(store: projectStore) },
        ]
        if let projectID = appState.activeProjectID {
            items.append(CommandPaletteItem(title: "Remove Project", subtitle: nil, category: "Projects", keybind: nil) {
                appState.removeProject(projectID)
                projectStore.remove(id: projectID)
            })
        }
        return items
    }

    private var windowActions: [CommandPaletteItem] {
        [
            CommandPaletteItem(
                title: "Toggle Sidebar",
                subtitle: nil,
                category: "Window",
                keybind: shortcut(.toggleSidebar)
            ) { appState.sidebarVisible.toggle() },
            CommandPaletteItem(
                title: "Close Window",
                subtitle: nil,
                category: "Window",
                keybind: shortcut(.closeWindow)
            ) {
                (NSApp.delegate as? AppDelegate)?.mainWindow?.orderOut(nil)
            },
        ]
    }

    // MARK: - Project items

    private var projectItems: [CommandPaletteItem] {
        projectStore.projects.map { projectItem($0, category: "Project") }
    }

    /// Top 5 most recently visited projects, excluding the currently active one
    /// (no point offering to switch to where the user already is). Falls back
    /// to the first projects in the store when there's no recency history yet.
    private var recentProjectItems: [CommandPaletteItem] {
        let recent = appState.recentProjects(from: projectStore.projects, limit: 10)
            .filter { $0.id != appState.activeProjectID }
        let pool = recent.isEmpty
            ? projectStore.projects.filter { $0.id != appState.activeProjectID }
            : recent
        return pool.prefix(5).map { projectItem($0, category: "Recent") }
    }

    private func projectItem(_ project: Project, category: String) -> CommandPaletteItem {
        CommandPaletteItem(
            title: project.name,
            subtitle: project.path,
            category: category,
            keybind: nil
        ) {
            appState.selectProject(project)
        }
    }

    // MARK: - Directory completions

    private var directoryCompletions: [CommandPaletteItem] {
        let q = searchQuery
        guard !q.isEmpty else { return [] }

        // Expand ~ and resolve the path
        let expanded = (q as NSString).expandingTildeInPath
        let isAbsolute = expanded.hasPrefix("/")
        guard isAbsolute else { return [] }

        let fm = FileManager.default
        let dir: String
        let prefix: String
        let exactDir: String?

        if fm.fileExists(atPath: expanded, isDirectory: nil) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: expanded, isDirectory: &isDir)
            if isDir.boolValue {
                dir = expanded
                prefix = ""
                exactDir = expanded
            } else {
                dir = (expanded as NSString).deletingLastPathComponent
                prefix = (expanded as NSString).lastPathComponent
                exactDir = nil
            }
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
            exactDir = nil
        }

        guard fm.fileExists(atPath: dir) else { return [] }

        let existingByPath = Dictionary(uniqueKeysWithValues: projectStore.projects.map { ($0.path, $0) })

        var items: [CommandPaletteItem] = []

        // If the query fully matches an existing directory, surface it as the
        // top result so the user can open (or switch to) it directly.
        if let exact = exactDir {
            let name = (exact as NSString).lastPathComponent
            items.append(directoryItem(name: name, fullPath: exact, existing: existingByPath[exact]))
        }

        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        items += entries
            .filter { name in
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return false }
                guard !name.hasPrefix(".") else { return false }
                return prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased())
            }
            .prefix(10)
            .map { name in
                let full = (dir as NSString).appendingPathComponent(name)
                return directoryItem(name: name, fullPath: full, existing: existingByPath[full])
            }

        return items
    }

    /// Returns an item that opens a directory as a new project, or switches to
    /// the matching existing project when `existing` is provided.
    private func directoryItem(name: String, fullPath: String, existing: Project?) -> CommandPaletteItem {
        if let existing {
            return CommandPaletteItem(
                title: existing.name,
                subtitle: "Switch to project: \(fullPath)",
                category: "Directories",
                keybind: nil
            ) { [appState] in
                appState.selectProject(existing)
            }
        }
        return CommandPaletteItem(
            title: name,
            subtitle: "Open as new project: \(fullPath)",
            category: "Directories",
            keybind: nil
        ) { [projectStore, appState] in
            let project = Project(
                name: name,
                path: fullPath,
                sortOrder: projectStore.projects.count
            )
            projectStore.add(project)
            appState.selectProject(project)
        }
    }

    private func shortcut(_ action: HotkeyAction) -> String? {
        let raw = HotkeyRegistry.selectedShortcutString(for: action)
        let display = HotkeyRegistry.displayString(for: raw)
        return display == "Disabled" ? nil : display
    }
}

// MARK: - Row

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(MactermTheme.fg)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(MactermTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let keybind = item.keybind {
                Text(keybind)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MactermTheme.fgDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? MactermTheme.surface : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}
