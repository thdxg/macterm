import AppKit
import Foundation

@MainActor @Observable
final class AppState {
    var activeProjectID: UUID? {
        didSet { Preferences.shared.activeProjectID = activeProjectID }
    }

    var workspaces: [UUID: Workspace] = [:]
    var sidebarVisible = true
    var pendingClosePane: PendingClosePane?
    var isCommandPaletteVisible = false
    private(set) var hasRestoredSelection = false

    /// Most-recent-first stack of project IDs. Persisted to UserDefaults.
    @ObservationIgnored
    private var projectRecency = RecencyStack<UUID>(limit: 50)
    private let recencyKey = "macterm.projectRecency"

    struct PendingClosePane: Equatable {
        let paneID: UUID
        let projectID: UUID
    }

    // Tab cycling state (Ctrl+Tab)
    private var tabCycleOrder: [UUID] = []
    private var tabCycleIndex: Int = 0
    var isTabCycling: Bool { !tabCycleOrder.isEmpty }

    private let workspaceStore: WorkspaceStore
    private var autoTileObserver: Any?

    init(workspaceStore: WorkspaceStore = WorkspaceStore()) {
        self.workspaceStore = workspaceStore
        autoTileObserver = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
        let restored = (UserDefaults.standard.stringArray(forKey: recencyKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        projectRecency = RecencyStack<UUID>(limit: 50, items: restored)
    }

    private func recordProjectVisit(_ projectID: UUID) {
        projectRecency.push(projectID)
        UserDefaults.standard.set(projectRecency.items.map(\.uuidString), forKey: recencyKey)
    }

    /// Recently-visited projects, filtered to only those still present in the store.
    func recentProjects(from projects: [Project], limit: Int = 5) -> [Project] {
        let valid = Set(projects.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return projectRecency.top(limit, in: valid).compactMap { byID[$0] }
    }

    private func rebalanceAllWorkspacesIfEnabled() {
        guard Preferences.shared.autoTilingEnabled else { return }
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
        if let id = Preferences.shared.activeProjectID,
           projects.contains(where: { $0.id == id })
        {
            activeProjectID = id
            recordProjectVisit(id)
            ensureWorkspace(projectID: id, projects: projects)
        }
    }

    func saveWorkspaces() {
        workspaceStore.save(WorkspaceSerializer.snapshot(workspaces))
    }

    // MARK: - Project

    func selectProject(_ project: Project) {
        activeProjectID = project.id
        recordProjectVisit(project.id)
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
                pane.destroySurface()
            }
        }
        workspaces.removeValue(forKey: projectID)
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    // MARK: - Tabs

    func createTab(projectID: UUID, projectPath: String) {
        guard let ws = workspaces[projectID] else { return }
        ws.createTab(projectPath: projectPath)
        saveWorkspaces()
    }

    /// Convenience overload: look up the project's canonical path from the
    /// given projects list so new tabs always land in the project directory,
    /// not whatever cwd the last pane drifted to.
    func createTab(projectID: UUID, projects: [Project]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        createTab(projectID: projectID, projectPath: project.path)
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        for pane in tab.splitRoot.allPanes() {
            pane.destroySurface()
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
        let currentIndex =
            allTabs.firstIndex { $0.0.id == activeProjectID && $0.1.id == currentTabID } ?? 0
        let newIndex: Int =
            switch direction {
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
              let paneID = tab.focusedPaneID
        else { return }
        tab.split(paneID: paneID, direction: direction)
        saveWorkspaces()
    }

    func resizePane(_ direction: PaneFocusDirection, projectID: UUID, delta: CGFloat = 0.03) {
        workspaces[projectID]?.activeTab?.resize(direction, delta: delta)
        saveWorkspaces()
    }

    func closePane(_ paneID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        // Find the tab that actually contains this pane (not just the active tab)
        guard let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) else {
            return
        }
        switch tab.removePane(paneID) {
        case .onlyPaneLeft:
            closeTab(tab.id, projectID: projectID)
        case .removed:
            saveWorkspaces()
        case .notFound:
            break
        }
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        let pane = workspaces[projectID]?.tabs
            .compactMap { $0.splitRoot.findPane(id: paneID) }
            .first
        if pane?.nsView?.needsConfirmQuit() == true {
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
