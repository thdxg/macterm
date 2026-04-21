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
                    if projectHasAnyTab(project) {
                        WorkspaceView(project: project)
                            .id(project.id)
                    } else {
                        EmptyProjectView(project: project)
                            .id(project.id)
                    }
                } else {
                    WelcomeView()
                }
            }
            .navigationTitle(activeProject?.name ?? "Macterm")
            .navigationSubtitle(activeTabTitle)
        }
        .background(WindowStyler())
        .overlay {
            if appState.isCommandPaletteVisible {
                CommandPaletteOverlay()
            }
        }
        .task {
            guard !appState.hasRestoredSelection else { return }
            appState.restoreSelection(projects: projectStore.projects)
        }
        .onChange(of: appState.sidebarVisible) { _, visible in
            columnVisibility = visible ? .automatic : .detailOnly
        }
        .onChange(of: appState.isCommandPaletteVisible) { _, visible in
            // When the palette closes, hand first responder back to the focused
            // terminal view so typing resumes without requiring a mouse click.
            if !visible {
                DispatchQueue.main.async { restoreFocusToActivePane() }
            }
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

    private func projectHasAnyTab(_ project: Project) -> Bool {
        !(appState.workspaces[project.id]?.tabs.isEmpty ?? true)
    }

    private func restoreFocusToActivePane() {
        guard let projectID = appState.activeProjectID,
              let tab = appState.workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID,
              let pane = tab.splitRoot.findPane(id: paneID),
              let view = pane.nsView,
              let window = view.window
        else { return }
        window.makeFirstResponder(view)
        view.notifySurfaceFocused()
    }

    private var activeTabTitle: String {
        guard let project = activeProject else { return "" }
        return project.path
    }
}

struct WelcomeView: View {
    private var shortcuts: [(HotkeyAction, String)] {
        [
            (.openProject, "Open a project"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text("Macterm")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MactermTheme.fg)
                Text("No project selected")
                    .font(.system(size: 12))
                    .foregroundStyle(MactermTheme.fgMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MactermTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct EmptyProjectView: View {
    let project: Project

    private var shortcuts: [(HotkeyAction, String)] {
        [
            (.newTab, "New tab"),
            (.openProject, "Open another project"),
            (.toggleSidebar, "Toggle sidebar"),
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MactermTheme.fg)
                Text(project.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcuts, id: \.0) { action, label in
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(MactermTheme.fgMuted)
                            .frame(width: 160, alignment: .leading)
                        Text(HotkeyRegistry.displayString(for: HotkeyRegistry.selectedShortcutString(for: action)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MactermTheme.fgDim)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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
                    let pane = tab.splitRoot.findPane(id: paneID)
                    let livePwd = pane?.nsView?.currentPwd
                    let sourcePath = livePwd ?? pane?.projectPath ?? project.path
                    let (newRoot, newID) = tab.splitRoot.splitting(
                        paneID: paneID, direction: dir, position: .second, projectPath: sourcePath
                    )
                    tab.splitRoot = newRoot
                    if let newID { tab.focusPane(newID) }
                    if Preferences.shared.autoTilingEnabled { tab.splitRoot.rebalanced() }
                    appState.saveWorkspaces()
                },
                onClosePane: { appState.requestClosePane($0, projectID: project.id) }
            )
            .id(tab.splitRoot.id)
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
            window.tabbingMode = .disallowed
            applyStyle(to: window)
            context.coordinator.observe(window: window)
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            context.coordinator.interceptClose(window: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    private func applyStyle(to window: NSWindow) {
        window.isOpaque = true
        window.backgroundColor = MactermTheme.nsBg
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        weak var swiftuiDelegate: (any NSWindowDelegate)?

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

        @MainActor
        func interceptClose(window: NSWindow) {
            swiftuiDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        /// Forward everything else to SwiftUI's delegate
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return swiftuiDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if swiftuiDelegate?.responds(to: aSelector) == true { return swiftuiDelegate }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
