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
    @State
    private var selection: SidebarItem?
    /// First-responder for the sidebar List, driven by `appState.sidebarFocusMode`
    /// (the Focus Sidebar hotkey). When focused, the native List shows the focus
    /// ring on the selected row and ↑/↓ move it.
    @FocusState
    private var listFocused: Bool

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
                            moveTargets: projectStore.projects.filter { $0.id != project.id },
                            onClose: { appState.closeTab(tab.id, projectID: project.id) },
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
                    }
                    .onMove { source, destination in
                        appState.workspaces[project.id]?.reorderTabs(fromOffsets: source, toOffset: destination)
                        appState.saveWorkspaces()
                    }
                } label: {
                    SidebarProjectRow(project: project, index: projectIndex + 1) {
                        appState.selectProject(project)
                        appState.createTab(projectID: project.id, projectPath: project.path)
                        expandedProjects.insert(project.id)
                    } onRename: {
                        projectStore.rename(id: project.id, to: $0)
                    } onUnload: {
                        appState.unloadProject(project.id)
                    } onRemove: {
                        expandedProjects.remove(project.id)
                        appState.removeProject(project.id)
                        projectStore.remove(id: project.id)
                    }
                    .tag(SidebarItem.project(project.id))
                }
            }
            .onMove { source, destination in
                projectStore.reorder(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
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
        .onChange(of: selection) { _, item in
            // In Focus Sidebar mode, arrowing only moves the tentative focus ring
            // — the active tab isn't committed until Enter (handled below).
            guard !appState.sidebarFocusMode, let item else { return }
            commitSelection(item)
        }
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID { expandedProjects.insert(newID) }
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onChange(of: appState.sidebarFocusMode) { _, on in
            // Grab first-responder when entering the mode (already open case);
            // release it when leaving (AppState restores terminal focus).
            listFocused = on
        }
        .onKeyPress(.return) {
            guard appState.sidebarFocusMode else { return .ignored }
            if let item = selection { commitSelection(item) }
            appState.exitSidebarFocus()
            return .handled
        }
        .onExitCommand {
            guard appState.sidebarFocusMode else { return }
            // Cancel: drop the tentative ring back onto the still-active tab,
            // then restore the sidebar's prior open/closed state and terminal focus.
            syncSelection()
            appState.exitSidebarFocus()
        }
        .onAppear {
            if let id = appState.activeProjectID { expandedProjects.insert(id) }
            syncSelection()
            // The sidebar may have been collapsed when Focus Sidebar was invoked;
            // it mounts only once forced open, so claim focus here too.
            if appState.sidebarFocusMode { listFocused = true }
        }
    }

    /// Commit a sidebar selection to the workspace (select the project, and the
    /// tab if one was chosen). Shared by live click-selection and the Enter key
    /// in Focus Sidebar mode.
    private func commitSelection(_ item: SidebarItem) {
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

    private var activeTabID: UUID? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]?.activeTabID
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
