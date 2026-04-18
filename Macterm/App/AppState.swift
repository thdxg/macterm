import AppKit
import Foundation

@MainActor @Observable
final class AppState {
    var activeProjectID: UUID? {
        didSet { UserDefaults.standard.set(activeProjectID?.uuidString, forKey: "macterm.activeProjectID") }
    }

    var workspaces: [UUID: Workspace] = [:]
    var sidebarVisible = true
    var pendingClosePane: PendingClosePane?
    var isCommandPaletteVisible = false
    var commandPaletteMode: CommandPaletteMode = .command
    private(set) var hasRestoredSelection = false

    struct PendingClosePane: Equatable {
        let paneID: UUID
        let projectID: UUID
    }

    // Tab cycling state (Ctrl+Tab)
    private var tabCycleOrder: [UUID] = []
    private var tabCycleIndex: Int = 0
    var isTabCycling: Bool { !tabCycleOrder.isEmpty }

    private let workspaceStore = WorkspaceStore()
    private var autoTileObserver: Any?

    init() {
        autoTileObserver = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
    }

    private func rebalanceAllWorkspacesIfEnabled() {
        guard AutoTilePreference.isEnabled else { return }
        for ws in workspaces.values {
            for tab in ws.tabs {
                tab.splitRoot.rebalanced()
            }
        }
        saveWorkspaces()
    }

    // MARK: - Restore / Save

    func restoreSelection(projects: [Project]) {
        hasRestoredSelection = true
        let snapshots = workspaceStore.load()
        let valid = Set(projects.map(\.id))
        for ws in WorkspaceSerializer.restore(from: snapshots, validIDs: valid) {
            workspaces[ws.projectID] = ws
        }
        if let idString = UserDefaults.standard.string(forKey: "macterm.activeProjectID"),
           let id = UUID(uuidString: idString),
           projects.contains(where: { $0.id == id })
        {
            activeProjectID = id
            ensureWorkspace(projectID: id, projects: projects)
        }
    }

    func saveWorkspaces() {
        workspaceStore.save(WorkspaceSerializer.snapshot(workspaces))
    }

    // MARK: - Project

    func selectProject(_ project: Project) {
        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
    }

    /// Shows an open panel, adds the selected directory as a project, and selects it.
    /// Returns the new project if one was created, nil if cancelled.
    @discardableResult
    func openProject(store: ProjectStore) -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let project = Project(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false),
            sortOrder: store.projects.count
        )
        store.add(project)
        selectProject(project)
        return project
    }

    func removeProject(_ projectID: UUID) {
        if let ws = workspaces[projectID] {
            for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
                TerminalViewCache.shared.remove(for: pane.id)
            }
        }
        workspaces.removeValue(forKey: projectID)
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    // MARK: - Tabs

    func createTab(projectID: UUID, projectPath: String? = nil) {
        guard let ws = workspaces[projectID] else { return }
        let path = projectPath
            ?? ws.activeTab?.splitRoot.allPanes().first?.projectPath
            ?? ""
        ws.createTab(projectPath: path)
        saveWorkspaces()
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        for pane in tab.splitRoot.allPanes() {
            TerminalViewCache.shared.remove(for: pane.id)
        }
        ws.closeTab(tabID)
        saveWorkspaces()
    }

    func selectTab(_ tabID: UUID, projectID: UUID) {
        workspaces[projectID]?.selectTab(tabID)
    }

    func selectNextTab(projectID: UUID) {
        workspaces[projectID]?.selectNextTab()
    }

    func selectPreviousTab(projectID: UUID) {
        workspaces[projectID]?.selectPreviousTab()
    }

    func cycleRecentTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        if tabCycleOrder.isEmpty {
            tabCycleOrder = ws.recencyOrder()
            tabCycleIndex = 0
        }
        guard tabCycleOrder.count > 1 else { return }
        tabCycleIndex = (tabCycleIndex + 1) % tabCycleOrder.count
        ws.peekTab(tabCycleOrder[tabCycleIndex])
    }

    func commitTabCycle(projectID: UUID) {
        guard !tabCycleOrder.isEmpty, let ws = workspaces[projectID] else {
            tabCycleOrder = []
            return
        }
        let selectedID = tabCycleOrder[tabCycleIndex]
        tabCycleOrder = []
        tabCycleIndex = 0
        ws.selectTab(selectedID)
        saveWorkspaces()
    }

    enum GlobalTabDirection { case next, previous }

    func selectGlobalTab(_ direction: GlobalTabDirection, projects: [Project]) {
        let allTabs = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p, $0) }
        }
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex = allTabs.firstIndex { $0.0.id == activeProjectID && $0.1.id == currentTabID } ?? 0
        let newIndex: Int = switch direction {
        case .next: (currentIndex + 1) % allTabs.count
        case .previous: (currentIndex - 1 + allTabs.count) % allTabs.count
        }
        let (project, tab) = allTabs[newIndex]

        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
        workspaces[project.id]?.selectTab(tab.id)
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        workspaces[projectID]?.selectTabByIndex(index)
    }

    // MARK: - Splits

    func splitPane(direction: SplitDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let pane = tab.focusedPane
        else { return }
        let livePwd = TerminalViewCache.shared.existingView(for: pane.id)?.currentPwd
        let sourcePath = livePwd ?? pane.projectPath
        let (newRoot, newPaneID) = tab.splitRoot.splitting(
            paneID: pane.id,
            direction: direction,
            position: .second,
            projectPath: sourcePath
        )
        tab.splitRoot = newRoot
        if let newPaneID { tab.focusPane(newPaneID) }
        if AutoTilePreference.isEnabled { tab.splitRoot.rebalanced() }
        saveWorkspaces()
    }

    func resizePane(_ direction: PaneFocusDirection, projectID: UUID, delta: CGFloat = 0.03) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        tab.splitRoot = tab.splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
        saveWorkspaces()
    }

    func closePane(_ paneID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        // Find the tab that actually contains this pane (not just the active tab)
        guard let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) else { return }
        TerminalViewCache.shared.remove(for: paneID)
        let panes = tab.splitRoot.allPanes()
        if panes.count <= 1 {
            closeTab(tab.id, projectID: projectID)
        } else {
            if let newRoot = tab.splitRoot.removing(paneID: paneID) {
                tab.splitRoot = newRoot
                tab.paneFocusHistory.removeAll { $0 == paneID }
                if tab.focusedPaneID == paneID {
                    tab.focusedPaneID = tab.nextFocusAfterClose()
                }
                if AutoTilePreference.isEnabled { tab.splitRoot.rebalanced() }
            }
            saveWorkspaces()
        }
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        if TerminalViewCache.shared.needsConfirmQuit(for: paneID) {
            pendingClosePane = PendingClosePane(paneID: paneID, projectID: projectID)
            return
        }
        closePane(paneID, projectID: projectID)
    }

    func confirmPendingClosePane() {
        guard let pending = pendingClosePane else { return }
        pendingClosePane = nil
        closePane(pending.paneID, projectID: pending.projectID)
    }

    func cancelPendingClosePane() {
        pendingClosePane = nil
    }

    func focusPane(_ paneID: UUID, projectID: UUID) {
        workspaces[projectID]?.activeTab?.focusPane(paneID)
    }

    func focusedPane(for projectID: UUID) -> Pane? {
        workspaces[projectID]?.activeTab?.focusedPane
    }

    // MARK: - Pane focus navigation

    func focusPaneInDirection(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let focusedID = tab.focusedPaneID
        else { return }
        if let bestID = tab.splitRoot.nearestPane(from: focusedID, direction: direction) {
            tab.focusPane(bestID)
        }
    }

    // MARK: - Project navigation

    func selectNextProject(projects: [Project]) {
        guard projects.count > 1, let current = activeProjectID,
              let i = projects.firstIndex(where: { $0.id == current })
        else { return }
        let project = projects[(i + 1) % projects.count]
        selectProject(project)
    }

    func selectPreviousProject(projects: [Project]) {
        guard projects.count > 1, let current = activeProjectID,
              let i = projects.firstIndex(where: { $0.id == current })
        else { return }
        let project = projects[(i - 1 + projects.count) % projects.count]
        selectProject(project)
    }

    // MARK: - Private

    private func ensureWorkspace(projectID: UUID, path: String) {
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, projectPath: path)
        }
    }

    private func ensureWorkspace(projectID: UUID, projects: [Project]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        ensureWorkspace(projectID: projectID, path: project.path)
    }
}
