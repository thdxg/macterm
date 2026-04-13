import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarContent()
                .navigationSplitViewColumnWidth(min: 140, ideal: 180, max: 280)
        } detail: {
            ZStack {
                MactermTheme.terminalBg
                if let project = activeProjectWithWorkspace {
                    WorkspaceView(project: project)
                        .id(project.id)
                } else {
                    WelcomeView()
                }
            }
            .navigationTitle(activeProject?.name ?? "Macterm")
            .navigationSubtitle(activeTabTitle)
        }
        .background(WindowStyler())
        .onAppear {
            appState.restoreSelection(projects: projectStore.projects)
        }
        .onChange(of: appState.sidebarVisible) { _, visible in
            columnVisibility = visible ? .automatic : .detailOnly
        }
    }

    private var activeProject: Project? {
        guard let pid = appState.activeProjectID else { return nil }
        return projectStore.projects.first { $0.id == pid }
    }

    private var activeProjectWithWorkspace: Project? {
        guard let project = activeProject, appState.workspaces[project.id] != nil else { return nil }
        return project
    }

    private var activeTabTitle: String {
        guard let project = activeProject,
              let ws = appState.workspaces[project.id],
              let tab = ws.activeTab
        else { return "" }
        return tab.title
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Text("No project selected")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("⌘O to open a project")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceView: View {
    let project: Project
    @Environment(AppState.self)
    private var appState

    var body: some View {
        if let ws = appState.workspaces[project.id], let tab = ws.activeTab {
            SplitTreeView(
                node: tab.splitRoot,
                focusedPaneID: tab.focusedPaneID,
                isActiveProject: true,
                projectID: project.id,
                onFocusPane: { appState.focusPane($0, projectID: project.id) },
                onSplit: { paneID, dir in
                    let (newRoot, newID) = tab.splitRoot.splitting(
                        paneID: paneID, direction: dir, position: .second, projectPath: project.path
                    )
                    tab.splitRoot = newRoot
                    if let newID { tab.focusedPaneID = newID }
                    appState.saveWorkspaces()
                },
                onClosePane: { appState.requestClosePane($0, projectID: project.id) }
            )
            .id(tab.id)
        }
    }
}

private struct WindowStyler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            applyStyle(to: window)
            context.coordinator.observe(window: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    private func applyStyle(to window: NSWindow) {
        window.isOpaque = true
        window.backgroundColor = MactermTheme.nsBg
    }

    final class Coordinator {
        nonisolated(unsafe) private var observer: Any?

        @MainActor
        func observe(window: NSWindow) {
            observer = NotificationCenter.default.addObserver(
                forName: .mactermConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated {
                    window.isOpaque = true
                    window.backgroundColor = MactermTheme.nsBg
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
