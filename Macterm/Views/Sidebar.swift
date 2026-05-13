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
    @State
    private var expandedProjects: Set<UUID> = []
    @State
    private var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(projectStore.projects) { project in
                let ws = appState.workspaces[project.id]
                let tabs = ws?.tabs ?? []

                DisclosureGroup(isExpanded: Binding(
                    get: { expandedProjects.contains(project.id) },
                    set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
                )) {
                    ForEach(tabs) { tab in
                        SidebarTabRow(tab: tab) {
                            appState.closeTab(tab.id, projectID: project.id)
                        } onRename: { newName in
                            tab.customTitle = newName.isEmpty ? nil : newName
                            appState.saveWorkspaces()
                        }
                        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
                    }
                    .onMove { source, destination in
                        appState.workspaces[project.id]?.reorderTabs(fromOffsets: source, toOffset: destination)
                        appState.saveWorkspaces()
                    }
                } label: {
                    SidebarProjectRow(project: project) {
                        appState.selectProject(project)
                        appState.createTab(projectID: project.id, projectPath: project.path)
                        expandedProjects.insert(project.id)
                    } onRename: {
                        projectStore.rename(id: project.id, to: $0)
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
        .scrollContentBackground(.hidden)
        .background(MactermTheme.bg)
        .safeAreaInset(edge: .bottom) {
            Button {
                openProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
    let onNewTab: () -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void
    @Environment(AppState.self)
    private var appState
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @FocusState
    private var focused: Bool

    var body: some View {
        Label {
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
        } icon: {
            Image(systemName: "folder.fill")
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
            Button("Remove Project", role: .destructive, action: onRemove)
        }
        .onChange(of: appState.renamingProjectID) { _, id in
            if id == project.id { beginRename() }
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
    let onClose: () -> Void
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @State
    private var preEditCustomTitle: String? = nil
    @FocusState
    private var focused: Bool

    var body: some View {
        Label {
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
        } icon: {
            Image(systemName: "terminal")
        }
        .contextMenu {
            Button("Rename Tab") { beginRename() }
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

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}
