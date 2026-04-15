import AppKit
import SwiftUI

// MARK: - Model

enum CommandPaletteMode {
    case command
    case project
}

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
            .id("palette-\(appState.commandPaletteMode)")
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

    private var mode: CommandPaletteMode {
        query.hasPrefix(">") ? .command : appState.commandPaletteMode
    }

    private var searchQuery: String {
        if query.hasPrefix(">") {
            return String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return query.trimmingCharacters(in: .whitespaces)
    }

    private func computeItems() -> [CommandPaletteItem] {
        switch mode {
        case .command:
            return commandItems.filter { fuzzyMatch(query: searchQuery, target: $0.title) }
        case .project:
            let existing = projectItems.filter {
                fuzzyMatch(query: searchQuery, target: $0.title) ||
                    fuzzyMatch(query: searchQuery, target: $0.subtitle ?? "")
            }
            return existing + directoryCompletions
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fgMuted)
                TextField(mode == .command ? "Type a command..." : "Search projects...", text: $query)
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
                                CommandPaletteRow(
                                    item: item,
                                    isSelected: idx == selectedIndex
                                )
                                .id(idx)
                                .onTapGesture {
                                    selectedIndex = idx
                                    execute()
                                }
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
            query = appState.commandPaletteMode == .command ? "> " : ""
            selectedIndex = 0
            isFieldFocused = true
            refreshItems()
        }
        .onChange(of: query) {
            selectedIndex = 0
            refreshItems()
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
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
        if mode == .project {
            let dirs = list.filter { $0.category == "Directories" }
            let projects = list.filter { $0.category != "Directories" }
            var sections: [Section] = []
            if !projects.isEmpty { sections.append(Section(category: nil, items: projects)) }
            if !dirs.isEmpty { sections.append(Section(category: "Directories", items: dirs)) }
            return sections
        }
        // Preserve category order from commandItems
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
        projectStore.projects.map { project in
            CommandPaletteItem(
                title: project.name,
                subtitle: project.path,
                category: nil,
                keybind: nil
            ) {
                appState.selectProject(project)
            }
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

        if fm.fileExists(atPath: expanded, isDirectory: nil) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: expanded, isDirectory: &isDir)
            if isDir.boolValue {
                dir = expanded
                prefix = ""
            } else {
                dir = (expanded as NSString).deletingLastPathComponent
                prefix = (expanded as NSString).lastPathComponent
            }
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }

        guard fm.fileExists(atPath: dir) else { return [] }

        let existingPaths = Set(projectStore.projects.map(\.path))

        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return entries
            .filter { name in
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return false }
                guard !name.hasPrefix(".") else { return false }
                guard !existingPaths.contains(full) else { return false }
                return prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased())
            }
            .prefix(10)
            .map { name in
                let full = (dir as NSString).appendingPathComponent(name)
                return CommandPaletteItem(
                    title: name,
                    subtitle: "Open as new project: \(full)",
                    category: "Directories",
                    keybind: nil
                ) { [projectStore, appState] in
                    let project = Project(
                        name: name,
                        path: full,
                        sortOrder: projectStore.projects.count
                    )
                    projectStore.add(project)
                    appState.selectProject(project)
                }
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
