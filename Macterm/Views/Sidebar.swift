import SwiftUI

private enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)
}

struct SidebarContent: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @AppStorage(Preferences.Keys.showNewProjectButton)
    private var showNewProjectButton = true
    @State
    private var expandedProjects: Set<UUID> = []
    /// A Set (not a lone optional) so the sidebar supports native multi-select:
    /// Cmd/Shift-click extends the selection, and a right-click acts on every
    /// selected row at once (see `.contextMenu(forSelectionType:)` below).
    @State
    private var selection: Set<SidebarItem> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(projectStore.projects.enumerated()), id: \.element.id) { projectIndex, project in
                let ws = appState.workspaces[project.id]
                let tabs = ws?.tabs ?? []

                DisclosureGroup(isExpanded: Binding(
                    get: { expandedProjects.contains(project.id) },
                    set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
                )) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                        SidebarTabRow(
                            tab: tab,
                            index: tabIndex + 1,
                            isActive: ws?.activeTabID == tab.id && appState.activeProjectID == project.id,
                            onRename: { newName in
                                tab.customTitle = newName.isEmpty ? nil : newName
                                appState.saveWorkspaces()
                            }
                        )
                        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
                    }
                    .onMove { source, destination in
                        appState.workspaces[project.id]?.reorderTabs(fromOffsets: source, toOffset: destination)
                        appState.saveWorkspaces()
                    }
                } label: {
                    SidebarProjectRow(project: project, index: projectIndex + 1) {
                        projectStore.rename(id: project.id, to: $0)
                    }
                    .tag(SidebarItem.project(project.id))
                }
            }
            .onMove { source, destination in
                projectStore.reorder(fromOffsets: source, toOffset: destination)
            }
        }
        // A single list-level context menu instead of one per row: the native
        // multi-select menu. Its closure receives the exact set the menu should
        // act on — right-clicking inside a multi-selection yields all selected
        // rows; right-clicking an unselected row yields just that row. This is
        // what lets "Remove N Projects" / "Close N Tabs" work.
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            contextMenu(for: items)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // No background here: the window's NSWindow.backgroundColor (set by
        // WindowAppearance) provides the translucent fill uniformly. Adding
        // another tinted layer here would make the sidebar read darker than
        // the surrounding strip.
        .safeAreaInset(edge: .bottom) {
            if showNewProjectButton {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            openProject()
                        } label: {
                            Label("New Project", systemImage: "plus")
                                .font(.body)
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .onChange(of: selection) { _, items in
            // Navigation follows a single selection only. A multi-selection is
            // for bulk actions (delete), so it must not yank the active project
            // or tab around as rows are added to the selection.
            guard items.count == 1, let item = items.first else { return }
            switch item {
            case let .project(projectID):
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
                appState.selectProject(project)
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }) {
                    appState.selectProject(project)
                    appState.selectTab(tabID, projectID: projectID)
                }
            }
        }
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID { expandedProjects.insert(newID) }
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onAppear {
            if let id = appState.activeProjectID { expandedProjects.insert(id) }
            syncSelection()
        }
    }

    private var activeTabID: UUID? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]?.activeTabID
    }

    private func syncSelection() {
        guard let pid = appState.activeProjectID,
              let ws = appState.workspaces[pid],
              let tabID = ws.activeTabID
        else {
            selection = appState.activeProjectID.map { [.project($0)] } ?? []
            return
        }
        let desired: Set<SidebarItem> = [.tab(projectID: pid, tabID: tabID)]
        if selection != desired { selection = desired }
    }

    // MARK: - Context menu

    /// The native multi-select context menu. `items` is the set the menu acts
    /// on, supplied by SwiftUI: the whole selection when the click lands inside
    /// it, or just the clicked row otherwise.
    @ViewBuilder
    private func contextMenu(for items: Set<SidebarItem>) -> some View {
        if items.count > 1 {
            bulkMenu(for: items)
        } else if let item = items.first {
            switch item {
            case let .project(id):
                if let project = projectStore.projects.first(where: { $0.id == id }) {
                    projectMenu(project)
                }
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }),
                   let tab = appState.workspaces[projectID]?.tabs.first(where: { $0.id == tabID })
                {
                    tabMenu(project: project, tab: tab)
                }
            }
        } else {
            // Right-click on empty space.
            Button("New Project", action: openProject)
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("New Tab") {
            appState.selectProject(project)
            appState.createTab(projectID: project.id, projectPath: project.path)
            expandedProjects.insert(project.id)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename Project") { appState.renamingProjectID = project.id }
        Divider()
        Button("Unload Project") { appState.unloadProject(project.id) }
            .disabled(!appState.isProjectLoaded(project.id))
        Button("Remove Project", role: .destructive) { removeSelection([.project(project.id)]) }
    }

    @ViewBuilder
    private func tabMenu(project: Project, tab: TerminalTab) -> some View {
        Button("Rename Tab") { appState.renamingTabID = tab.id }
        let moveTargets = projectStore.projects.filter { $0.id != project.id }
        if !moveTargets.isEmpty {
            Menu("Move to Project") {
                ForEach(moveTargets) { destination in
                    Button(destination.name) {
                        appState.moveTab(tab.id, from: project.id, to: destination.id, destPath: destination.path)
                        expandedProjects.insert(destination.id)
                    }
                }
            }
        }
        Divider()
        Button("Close Tab", role: .destructive) {
            removeSelection([.tab(projectID: project.id, tabID: tab.id)])
        }
    }

    @ViewBuilder
    private func bulkMenu(for items: Set<SidebarItem>) -> some View {
        let projectCount = items.count(where: { if case .project = $0 { true } else { false } })
        let tabCount = items.count - projectCount
        if projectCount == 0 {
            Button("Close \(tabCount) Tabs", role: .destructive) { removeSelection(items) }
        } else if tabCount == 0 {
            Button("Remove \(projectCount) Projects", role: .destructive) { removeSelection(items) }
        } else {
            Button("Remove \(items.count) Items", role: .destructive) { removeSelection(items) }
        }
    }

    /// Delete every item in `items`: close the selected tabs and remove the
    /// selected projects (with their `ProjectStore` entries). Tabs that belong
    /// to a project also being removed are skipped — `removeProject` already
    /// tears their surfaces down.
    private func removeSelection(_ items: Set<SidebarItem>) {
        var projectIDs: [UUID] = []
        var tabRefs: [(tabID: UUID, projectID: UUID)] = []
        for item in items {
            switch item {
            case let .project(id):
                projectIDs.append(id)
            case let .tab(projectID, tabID):
                tabRefs.append((tabID: tabID, projectID: projectID))
            }
        }

        let removedProjects = Set(projectIDs)
        appState.closeTabs(tabRefs.filter { !removedProjects.contains($0.projectID) })

        for id in projectIDs {
            expandedProjects.remove(id)
        }
        appState.removeProjects(projectIDs)
        for id in projectIDs {
            projectStore.remove(id: id)
        }

        selection = []
    }

    private func openProject() {
        if let project = appState.openProject(store: projectStore) {
            expandedProjects.insert(project.id)
        }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let index: Int
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol = "folder"
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @FocusState
    private var focused: Bool

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            Text(project.name)
                .lineLimit(1)
        }
    }

    var body: some View {
        Group {
            if projectIconSymbol == Preferences.noIcon {
                titleContent
                    .padding(.leading, 6)
            } else {
                Label {
                    titleContent
                } icon: {
                    SidebarRowIcon(symbol: projectIconSymbol, index: index)
                }
            }
        }
        .task(id: appState.renamingProjectID) {
            if appState.renamingProjectID == project.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingProjectID = nil
        renameText = project.name
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    let isActive: Bool
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @State
    private var preEditCustomTitle: String?
    @FocusState
    private var focused: Bool

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField(tab.autoTitle, text: $renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            Text(tab.sidebarTitle)
                .lineLimit(1)
        }
    }

    var body: some View {
        Group {
            if tabIconSymbol == Preferences.noIcon {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index)
                    }
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index)
                    } else {
                        SidebarRowIcon(symbol: tabIconSymbol, index: index)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingTabID = nil
        preEditCustomTitle = tab.customTitle
        renameText = tab.customTitle ?? ""
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != preEditCustomTitle {
            onRename(text)
        }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private var displayState: TerminalExecutionState {
        if tab.executionState == .running { return .running }
        // The tab the user is already looking at never needs an attention
        // indicator; a background tab's `done` checkmark is shown until it's
        // acknowledged. Visiting the tab clears all of its panes via the poll's
        // `acknowledgeFinishedCommandIfActive` (which acknowledges the whole
        // active tab, not just the focused pane, so the persisted state matches
        // what's displayed).
        return isActive ? .idle : tab.executionState
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

/// The tab icon with a coexisting status indicator (the maintainer's
/// suggestion): the user's chosen icon stays put, and status is additive.
///
/// - `running`: a small spinner replaces the icon (temporary prominence,
///   Xcode-build-navigator style).
/// - `done` (needs attention): the icon with a small solid status dot in the
///   bottom-trailing corner — like the Messages/FaceTime "available" dot. A
///   dot reads as "done/positive" without competing with the icon's identity,
///   and it avoids the heavy, off-platform look of a checkmark glyph badge.
/// - `idle`: the icon as-is.
private struct TabStatusGlyph: View {
    let state: TerminalExecutionState
    let symbol: String
    let index: Int

    var body: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .help("Running")
                .frame(width: 16, height: 16)
        case .done:
            SidebarRowIcon(symbol: symbol, index: index)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    // Opaque (not translucent) so it reads clearly over the
                    // icon and the sidebar background. Nested in a background
                    // ring so it stays legible over any icon color.
                    Circle()
                        .fill(.background)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        )
                        .offset(x: 2.5, y: 2.5)
                }
                .help("Done")
        case .idle:
            SidebarRowIcon(symbol: symbol, index: index)
                .foregroundStyle(.secondary)
                .help("Idle")
        }
    }
}

private struct SidebarRowIcon: View {
    let symbol: String
    let index: Int

    var body: some View {
        if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol)
        } else {
            Image(systemName: symbol)
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text("\(index)")
                .font(.body.monospacedDigit())
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
        } else {
            Text("\(index)")
                .font(.body.monospacedDigit())
        }
    }

    /// Maps the sentinel token (e.g. `number.circle.fill`) to the suffix used
    /// by the indexed SF Symbol (e.g. `circle.fill` in `1.circle.fill`).
    private var shapeSuffix: String? {
        switch variant {
        case Preferences.numberIconCircleFill: "circle.fill"
        case Preferences.numberIconCircle: "circle"
        case Preferences.numberIconSquareFill: "square.fill"
        case Preferences.numberIconSquare: "square"
        default: nil
        }
    }
}
