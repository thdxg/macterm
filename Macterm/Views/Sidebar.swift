import SwiftUI
import UniformTypeIdentifiers

private enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)
}

/// In-app drag payload for a sidebar tab row. Carries the tab's identity plus
/// its source project so a drop can tell a same-project reorder from a
/// cross-project move. `TerminalTab` itself is a live reference type (owns
/// surfaces) and must never be encoded/serialized — only these two UUIDs
/// travel, and the drop looks the tab back up by id.
struct MovableTab: Codable, Transferable {
    let tabID: UUID
    let sourceProjectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermTab)
    }
}

/// In-app drag payload for a sidebar project header — the project's id.
/// Project reordering is driven by this drag rather than `List`'s `.onMove`,
/// because `.onMove` puts the whole List in reorder mode and hijacks the tab
/// rows' `.draggable` gesture (so tab drag-and-drop never fired). With both
/// projects and tabs on the Transferable path, they coexist.
struct MovableProject: Codable, Transferable {
    let projectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermProject)
    }
}

extension UTType {
    static let mactermTab = UTType(exportedAs: "com.thdxg.macterm.tab-move")
    static let mactermProject = UTType(exportedAs: "com.thdxg.macterm.project-move")
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
    @State
    private var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(projectStore.projects.enumerated()), id: \.element.id) { projectIndex, project in
                projectSection(index: projectIndex, project: project)
            }
            // No `.onMove`: it puts the List in reorder mode and hijacks the tab
            // rows' `.draggable`, so tab drag-and-drop never fired. Project
            // reordering is instead driven by dragging the project header (a
            // `MovableProject` payload) so both drags share the Transferable
            // path and coexist. See `projectHeader`.
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
                        Menu {
                            Button("Local Folder…") { openProject() }
                            Button("Remote Machine…") {
                                appState.isNewRemoteProjectSheetPresented = true
                            }
                        } label: {
                            Label("New Project", systemImage: "plus")
                                .font(.body)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
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

    /// One project's disclosure section: its tab rows (draggable + a drop
    /// target that reorders/moves at the insertion offset) under a header that
    /// itself accepts drops (the append path for a collapsed/empty project).
    /// Extracted from `body` so each drag/drop closure type-checks in its own
    /// scope — inlined, the whole `List` blew the solver's time budget.
    @ViewBuilder
    private func projectSection(index projectIndex: Int, project: Project) -> some View {
        let ws = appState.workspaces[project.id]
        let tabs = ws?.tabs ?? []
        DisclosureGroup(isExpanded: Binding(
            get: { expandedProjects.contains(project.id) },
            set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
        )) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                tabRow(tab: tab, index: tabIndex, activeTabID: ws?.activeTabID, project: project)
            }
            // Single drop mechanism for both cases: SwiftUI reports the
            // insertion `offset` within THIS project's tab list. A drop from
            // the same project reorders to that slot; a drop from another
            // project moves the tab in at that slot. Replaces the old `.onMove`
            // (which is per-section and can't express a cross-project move).
            .dropDestination(for: MovableTab.self) { items, offset in
                receiveTabDrop(items, into: project, at: offset)
            }
        } label: {
            projectHeader(index: projectIndex, project: project)
        }
    }

    private func tabRow(tab: TerminalTab, index tabIndex: Int, activeTabID: UUID?, project: Project) -> some View {
        SidebarTabRow(
            tab: tab,
            index: tabIndex + 1,
            isActive: activeTabID == tab.id && appState.activeProjectID == project.id,
            moveTargets: projectStore.projects.filter { $0.id != project.id },
            onClose: { appState.requestCloseTab(tab.id, projectID: project.id) },
            onRename: { newName in
                tab.customTitle = newName.isEmpty ? nil : newName
                appState.saveWorkspaces()
            },
            onMoveToProject: { destination in
                appState.moveTab(tab.id, from: project.id, to: destination.id, destPath: destination.path)
                expandedProjects.insert(destination.id)
            }
        )
        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        // Drag a tab out to another project (or reorder within this one). The
        // payload is just IDs — the live tab is looked up on drop, never
        // serialized.
        .draggable(MovableTab(tabID: tab.id, sourceProjectID: project.id))
    }

    private func projectHeader(index projectIndex: Int, project: Project) -> some View {
        SidebarProjectRow(project: project, index: projectIndex + 1) {
            appState.selectProject(project)
            appState.createTab(projectID: project.id, projectPath: project.path)
            expandedProjects.insert(project.id)
        } onRename: {
            projectStore.rename(id: project.id, to: $0)
        } onUnload: {
            appState.requestUnloadProject(project.id)
        } onRemove: {
            appState.requestRemoveProject(project.id) {
                expandedProjects.remove(project.id)
                appState.removeProject(project.id)
                projectStore.remove(id: project.id)
            }
        }
        .tag(SidebarItem.project(project.id))
        // Drag the header to reorder projects (replaces the removed `.onMove`).
        .draggable(MovableProject(projectID: project.id))
        // Dropping a TAB onto the header appends it to that project — the only
        // drop path for a collapsed or empty project, whose tab ForEach renders
        // no rows to target.
        .dropDestination(for: MovableTab.self) { items, _ in
            receiveTabDrop(items, into: project, at: nil)
            return true
        } isTargeted: { targeted in
            // Spring-open a collapsed project while hovering a drag over it, so
            // the user can see where the tab will land.
            if targeted { expandedProjects.insert(project.id) }
        }
        // Dropping a PROJECT onto this header reorders it to this project's
        // slot. Stacked as a second `.dropDestination` because each accepts a
        // single payload type.
        .dropDestination(for: MovableProject.self) { items, _ in
            receiveProjectDrop(items, before: project)
            return true
        }
    }

    private var activeTabID: UUID? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]?.activeTabID
    }

    /// Apply a tab drag-and-drop. `index` is the insertion slot within the
    /// destination project's tab list (nil = append, used by header drops). A
    /// drop from the same project reorders; a drop from another project moves
    /// the live tab (surfaces and shells intact) into this one. SwiftUI can
    /// deliver more than one payload, so each is applied in order.
    private func receiveTabDrop(_ items: [MovableTab], into project: Project, at index: Int?) {
        for item in items {
            if item.sourceProjectID == project.id {
                if let index {
                    appState.reorderTab(item.tabID, inProject: project.id, toIndex: index)
                }
            } else {
                appState.moveTab(
                    item.tabID,
                    from: item.sourceProjectID,
                    to: project.id,
                    destPath: project.path,
                    toIndex: index
                )
            }
        }
        expandedProjects.insert(project.id)
    }

    /// Apply a project drag-and-drop: move the dragged project to the target
    /// project's slot. Uses `move(fromOffsets:toOffset:)` semantics — `toOffset`
    /// is the index in the CURRENT array where the item inserts (SwiftUI's
    /// convention), so a downward move lands after the target.
    private func receiveProjectDrop(_ items: [MovableProject], before target: Project) {
        let projects = projectStore.projects
        guard let targetIndex = projects.firstIndex(where: { $0.id == target.id }) else { return }
        for item in items {
            guard let fromIndex = projects.firstIndex(where: { $0.id == item.projectID }),
                  fromIndex != targetIndex
            else { continue }
            // Dropping onto a project means "land at its slot": inserting above
            // when dragging up, and (via move's toOffset convention) at the
            // target's position when dragging down.
            let toOffset = fromIndex < targetIndex ? targetIndex + 1 : targetIndex
            projectStore.reorder(fromOffsets: IndexSet(integer: fromIndex), toOffset: toOffset)
        }
    }

    private func syncSelection() {
        guard let pid = appState.activeProjectID,
              let ws = appState.workspaces[pid],
              let tabID = ws.activeTabID
        else {
            selection = appState.activeProjectID.map { .project($0) }
            return
        }
        let desired = SidebarItem.tab(projectID: pid, tabID: tabID)
        if selection != desired { selection = desired }
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
    let onNewTab: () -> Void
    let onRename: (String) -> Void
    let onUnload: () -> Void
    let onRemove: () -> Void
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
            HStack(spacing: 4) {
                Text(project.name)
                    .lineLimit(1)
                if project.isRemote {
                    // Remote project (#104): panes live on this host over ssh.
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(project.path)
                }
            }
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
        .contextMenu {
            Button("New Tab", action: onNewTab)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Divider()
            Button("Rename Project") { beginRename() }
            Divider()
            Button("Unload Project", action: onUnload)
                .disabled(!appState.isProjectLoaded(project.id))
            Button("Remove Project", role: .destructive, action: onRemove)
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
    let moveTargets: [Project]
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onMoveToProject: (Project) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons = true
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

    /// The tab's live agent logo, unless disabled in Settings.
    private var agentIcon: AgentIcon? {
        showAgentIcons ? tab.agentIcon : nil
    }

    var body: some View {
        Group {
            if tabIconSymbol == Preferences.noIcon {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index, agent: agentIcon)
                    } else if let agentIcon {
                        // "None" suppresses the user's icon, not the agent
                        // logo — a live status signal, like the else branch.
                        SidebarRowIcon(symbol: tabIconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(state: displayState, symbol: tabIconSymbol, index: index, agent: agentIcon)
                    } else {
                        SidebarRowIcon(symbol: tabIconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            Button("Rename Tab") { beginRename() }
            if !moveTargets.isEmpty {
                Menu("Move to Project") {
                    ForEach(moveTargets) { project in
                        Button(project.name) { onMoveToProject(project) }
                    }
                }
            }
            Divider()
            Button("Close Tab", action: onClose)
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
    var agent: AgentIcon?

    var body: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .help("Running")
                .frame(width: 16, height: 16)
        case .done:
            SidebarRowIcon(symbol: symbol, index: index, agent: agent)
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
                                .fill(MactermTheme.success)
                                .frame(width: 5, height: 5)
                        )
                        .offset(x: 2.5, y: 2.5)
                }
                .help("Done")
        case .idle:
            SidebarRowIcon(symbol: symbol, index: index, agent: agent)
                .foregroundStyle(.secondary)
                .help("Idle")
        }
    }
}

private extension AgentIcon {
    /// The agent's brand tint. These are vendor identity colors, not theme
    /// colors, so they're the one deliberate exception to "all colors come
    /// from MactermTheme". Monochrome brands (Cursor, Grok, opencode) use
    /// `.primary` so they stay black-on-light / white-on-dark like the brand.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // Anthropic coral
        case .codex: Color(red: 0xAB / 255, green: 0xAB / 255, blue: 0xAB / 255) // OpenAI light gray
        case .gemini: Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255) // Google blue
        case .copilot: Color(red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) // GitHub purple
        case .opencode,
             .cursor,
             .grok,
             .pi: .primary
        }
    }
}

private struct SidebarRowIcon: View {
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    /// Scales with the user's text size like the sibling SF Symbols do; a
    /// fixed 15pt would stay small next to enlarged row text.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    var body: some View {
        if let agent {
            // A live AI agent in the tab overrides the user's chosen icon —
            // the logo is a status signal, tinted with the agent's brand color
            // (overriding the row's .secondary tint).
            Image(agent.rawValue)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: agentIconSize, height: agentIconSize)
                .foregroundStyle(agent.brandColor)
        } else if Preferences.numberIconChoices.contains(symbol) {
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
