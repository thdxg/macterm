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

    struct PendingClosePane: Equatable {
        let paneID: UUID
        let projectID: UUID
    }

    private let workspaceStore = WorkspaceStore()
    private var viewCache: TerminalViewCache { TerminalViewCache.shared }

    // MARK: - Restore / Save

    func restoreSelection(projects: [Project]) {
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
                viewCache.remove(for: pane.id)
            }
        }
        workspaces.removeValue(forKey: projectID)
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    // MARK: - Tabs

    func createTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let path = ws.activeTab?.splitRoot.allPanes().first?.projectPath ?? ""
        ws.createTab(projectPath: path)
        saveWorkspaces()
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        for pane in tab.splitRoot.allPanes() {
            viewCache.remove(for: pane.id)
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

    func selectRecentTab(projectID: UUID) {
        workspaces[projectID]?.selectRecentTab()
    }

    func selectNextGlobalTab(projects: [Project]) {
        let allTabs = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p, $0) }
        }
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex = allTabs.firstIndex { $0.0.id == activeProjectID && $0.1.id == currentTabID } ?? -1
        let nextIndex = (currentIndex + 1) % allTabs.count
        let (nextProject, nextTab) = allTabs[nextIndex]

        activeProjectID = nextProject.id
        ensureWorkspace(projectID: nextProject.id, path: nextProject.path)
        workspaces[nextProject.id]?.selectTab(nextTab.id)
    }

    func selectPreviousGlobalTab(projects: [Project]) {
        let allTabs = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p, $0) }
        }
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex = allTabs.firstIndex { $0.0.id == activeProjectID && $0.1.id == currentTabID } ?? 0
        let prevIndex = (currentIndex - 1 + allTabs.count) % allTabs.count
        let (prevProject, prevTab) = allTabs[prevIndex]

        activeProjectID = prevProject.id
        ensureWorkspace(projectID: prevProject.id, path: prevProject.path)
        workspaces[prevProject.id]?.selectTab(prevTab.id)
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        workspaces[projectID]?.selectTabByIndex(index)
    }

    // MARK: - Splits

    func splitPane(direction: SplitDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let pane = tab.focusedPane
        else { return }
        let (newRoot, newPaneID) = tab.splitRoot.splitting(
            paneID: pane.id,
            direction: direction,
            position: .second,
            projectPath: pane.projectPath
        )
        tab.splitRoot = newRoot
        if let newPaneID { tab.focusedPaneID = newPaneID }
        saveWorkspaces()
    }

    func closePane(_ paneID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        // Find the tab that actually contains this pane (not just the active tab)
        guard let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) else { return }
        viewCache.remove(for: paneID)
        let panes = tab.splitRoot.allPanes()
        if panes.count <= 1 {
            closeTab(tab.id, projectID: projectID)
        } else {
            if let newRoot = tab.splitRoot.removing(paneID: paneID) {
                tab.splitRoot = newRoot
                if tab.focusedPaneID == paneID { tab.focusedPaneID = newRoot.allPanes().first?.id }
            }
            saveWorkspaces()
        }
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        if terminalViewCache.needsConfirmQuit(for: paneID) {
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
        workspaces[projectID]?.activeTab?.focusedPaneID = paneID
    }

    func focusedPane(for projectID: UUID) -> Pane? {
        workspaces[projectID]?.activeTab?.focusedPane
    }

    // MARK: - Pane focus navigation

    func focusPaneInDirection(_ direction: PaneFocusDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let focusedID = tab.focusedPaneID
        else { return }
        let frames = tab.splitRoot.paneFrames()
        guard let focusedFrame = frames[focusedID] else { return }

        var bestID: UUID?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for (id, frame) in frames where id != focusedID {
            guard isCandidate(frame, from: focusedFrame, direction: direction) else { continue }
            let dist = distance(from: focusedFrame, to: frame, direction: direction)
            if dist < bestDist { bestDist = dist
                bestID = id
            }
        }
        if let bestID { tab.focusedPaneID = bestID }
    }

    enum PaneFocusDirection { case left, right, up, down }

    private func isCandidate(_ c: CGRect, from f: CGRect, direction: PaneFocusDirection) -> Bool {
        switch direction {
        case .left: c.midX < f.midX
        case .right: c.midX > f.midX
        case .up: c.midY < f.midY
        case .down: c.midY > f.midY
        }
    }

    private func distance(from f: CGRect, to c: CGRect, direction: PaneFocusDirection) -> CGFloat {
        let axial: CGFloat
        let cross: CGFloat
        switch direction {
        case .left,
             .right:
            axial = abs(f.midX - c.midX)
            cross = abs(f.midY - c.midY)
        case .up,
             .down:
            axial = abs(f.midY - c.midY)
            cross = abs(f.midX - c.midX)
        }
        return axial + cross * 0.5
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

    // MARK: - View cache

    var terminalViewCache: TerminalViewCache { viewCache }

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
