import SwiftUI

struct SidebarContent: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var expandedProjects: Set<UUID> = []

    var body: some View {
        List {
            ForEach(projectStore.projects) { project in
                let isActive = project.id == appState.activeProjectID
                let ws = appState.workspaces[project.id]
                let tabs = ws?.tabs ?? []

                DisclosureGroup(isExpanded: Binding(
                    get: { expandedProjects.contains(project.id) },
                    set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
                )) {
                    ForEach(tabs) { tab in
                        let isActiveTab = isActive && tab.id == ws?.activeTabID
                        SidebarTabRow(tab: tab, isActive: isActiveTab) {
                            appState.selectProject(project)
                            appState.selectTab(tab.id, projectID: project.id)
                        } onClose: {
                            appState.closeTab(tab.id, projectID: project.id)
                        }
                    }
                } label: {
                    SidebarProjectRow(project: project, isSelected: isActive) {
                        appState.selectProject(project)
                    } onNewTab: {
                        appState.selectProject(project)
                        appState.createTab(projectID: project.id)
                        expandedProjects.insert(project.id)
                    } onRename: {
                        projectStore.rename(id: project.id, to: $0)
                    } onRemove: {
                        expandedProjects.remove(project.id)
                        appState.removeProject(project.id)
                        projectStore.remove(id: project.id)
                    }
                }
            }
            .onMove { source, destination in
                projectStore.reorder(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(MactermTheme.bg)
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 14)
        }
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
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID { expandedProjects.insert(newID) }
        }
        .onAppear {
            if let id = appState.activeProjectID { expandedProjects.insert(id) }
        }
    }

    private func openProject() {
        if let project = appState.openProject(store: projectStore) {
            expandedProjects.insert(project.id)
        }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let isSelected: Bool
    let onSelect: () -> Void
    let onNewTab: () -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void
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
                    .onExitCommand { isRenaming = false }
            } else {
                Text(project.name)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? MactermTheme.accent : MactermTheme.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("New Tab", action: onNewTab)
            Divider()
            Button("Rename Project") {
                renameText = project.name
                isRenaming = true
                focused = true
            }
            Divider()
            Button("Remove Project", role: .destructive, action: onRemove)
        }
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        isRenaming = false
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private var displayTitle: String {
        tab.sidebarTitle
    }

    var body: some View {
        Label {
            Text(displayTitle)
                .lineLimit(1)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? MactermTheme.fg : MactermTheme.fgMuted)
        } icon: {
            Image(systemName: "terminal")
                .foregroundStyle(isActive ? MactermTheme.fg : MactermTheme.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(isActive ? MactermTheme.accentSoft : Color.clear)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Close Tab", action: onClose)
        }
    }
}
