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
                // The window's NSWindow.backgroundColor (set by WindowAppearance)
                // fills the detail column at the configured opacity. No need
                // to paint another tinted layer here — doing so stacks two
                // translucent fills and the detail reads as darker than the
                // strip around the sidebar.
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    UpdateAvailableToolbarButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    TabSwitcherToolbarItem()
                }
            }
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
            guard !visible else { return }
            // Run a post-dismiss action if one was registered, otherwise return
            // focus to the active terminal pane so typing resumes immediately.
            if let action = appState.postPaletteAction {
                appState.postPaletteAction = nil
                DispatchQueue.main.async { action() }
            } else {
                DispatchQueue.main.async { appState.restoreFocusToActivePane() }
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

    private var activeTabTitle: String {
        guard let project = activeProject else { return "" }
        return project.path
    }
}

struct WelcomeView: View {
    private var shortcuts: [(HotkeyAction, String)] {
        [
            (.openProject, "Open a project"),
            (.toggleCommandPalette, "Command palette"),
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
            (.toggleCommandPalette, "Command palette"),
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
            let renderedNode: SplitNode = {
                if let zoomID = tab.zoomedPaneID, let pane = tab.splitRoot.findPane(id: zoomID) {
                    return .pane(pane)
                }
                return tab.splitRoot
            }()
            SplitTreeView(
                node: renderedNode,
                focusedPaneID: tab.focusedPaneID,
                zoomedPaneID: tab.zoomedPaneID,
                isActiveProject: true,
                projectID: project.id,
                onFocusPane: { appState.focusPane($0, projectID: project.id) },
                onSplit: { paneID, dir in
                    tab.split(paneID: paneID, direction: dir)
                    appState.saveWorkspaces()
                },
                onClosePane: { appState.requestClosePane($0, projectID: project.id) },
                onToggleZoom: { tab.toggleZoom(paneID: $0) }
            )
            .id(renderedNode.id)
            .overlay(alignment: .topTrailing) {
                if tab.zoomedPaneID != nil {
                    ZoomIndicator(onExit: { appState.toggleZoom(projectID: project.id) })
                        .padding(8)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// Small badge shown in the corner of a tab while one of its panes is zoomed.
/// Clicking it exits zoom and restores the full split layout.
struct ZoomIndicator: View {
    let onExit: () -> Void

    var body: some View {
        Button(action: onExit) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text("Zoomed")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MactermTheme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MactermTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(MactermTheme.border, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Exit zoom")
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
            // Let the content view extend under the titlebar so the sidebar
            // and terminal paint continuously up to the top of the window.
            // Without this the titlebar floats above the sidebar with a
            // visible boundary, which is jarring when both are translucent.
            window.styleMask.insert(.fullSizeContentView)
            WindowAppearance.sync(window: window)
            context.coordinator.observe(window: window)
            // Intercept the close button to hide instead of close,
            // preserving terminal surfaces and running processes.
            context.coordinator.interceptClose(window: window)
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    final class Coordinator: NSObject, NSWindowDelegate {
        nonisolated(unsafe) private var observer: Any?
        weak var swiftuiDelegate: (any NSWindowDelegate)?

        @MainActor
        func observe(window: NSWindow) {
            // Re-apply on config change. AppKit also rebuilds the titlebar
            // subviews on becomeMain / fullscreen transitions, so we resync
            // there too via the delegate hooks below.
            observer = NotificationCenter.default.addObserver(
                forName: .mactermConfigDidChange,
                object: nil,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { WindowAppearance.sync(window: window) }
            }
        }

        func windowDidBecomeMain(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidEnterFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowAppearance.sync(window: window)
            swiftuiDelegate?.windowDidExitFullScreen?(notification)
        }

        @MainActor
        func interceptClose(window: NSWindow) {
            swiftuiDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // During app termination AppKit asks every window if it can close.
            // The "hide instead of close" trick is only for the user clicking
            // the red close button while the app keeps running — when we're
            // shutting down, let the window actually close so the process can
            // exit instead of leaving an invisible window holding the app open.
            if AppTerminationState.isTerminating { return true }
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
