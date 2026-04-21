import Foundation

/// A single tab — owns a split-pane tree.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    var customTitle: String?
    var splitRoot: SplitNode
    var focusedPaneID: UUID?
    /// Most-recent-first stack of previously focused pane IDs
    /// (excludes the currently focused pane).
    @ObservationIgnored
    var paneFocusHistory = RecencyStack<UUID>(limit: 20)

    /// Record a focus change, pushing the previous pane onto history.
    func focusPane(_ paneID: UUID) {
        guard paneID != focusedPaneID else { return }
        if let current = focusedPaneID { paneFocusHistory.push(current) }
        paneFocusHistory.remove(paneID)
        focusedPaneID = paneID
    }

    /// Pick the next focus target after a pane is removed from the tree.
    /// Walks the history stack (skipping panes no longer in the tree), then
    /// falls back to the first pane in tree order.
    func nextFocusAfterClose() -> UUID? {
        let valid = Set(splitRoot.allPanes().map(\.id))
        paneFocusHistory.prune(keeping: valid)
        if let recent = paneFocusHistory.popValid(in: valid) { return recent }
        return splitRoot.allPanes().first?.id
    }

    var title: String {
        if let customTitle { return customTitle }
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.title).joined(separator: " | ")
    }

    var sidebarTitle: String {
        if let customTitle { return customTitle }
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.sidebarSegmentTitle).joined(separator: " | ")
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return nil }
        return splitRoot.findPane(id: focusedPaneID)
    }

    init(projectPath: String) {
        id = UUID()
        let pane = Pane(projectPath: projectPath)
        splitRoot = .pane(pane)
        focusedPaneID = pane.id
    }

    init(id: UUID, splitRoot: SplitNode, focusedPaneID: UUID?, customTitle: String? = nil) {
        self.id = id
        self.splitRoot = splitRoot
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
    }

    // MARK: - Split/resize/close operations

    //
    // These live on TerminalTab so both the main-window workspace flow and the
    // quick terminal can share the same split-tree mutation logic. Callers that
    // need persistence (AppState) handle saveWorkspaces themselves after calling
    // these; the quick terminal doesn't persist.

    /// Split the focused pane (or a specific pane) in `direction`, placing the
    /// new pane in the `.second` position. Returns the new pane ID if created.
    @discardableResult
    func split(paneID: UUID, direction: SplitDirection) -> UUID? {
        let pane = splitRoot.findPane(id: paneID)
        let livePwd = pane?.nsView?.currentPwd
        let sourcePath = livePwd ?? pane?.projectPath ?? NSHomeDirectory()
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID, direction: direction, position: .second, projectPath: sourcePath
        )
        splitRoot = newRoot
        if let newID { focusPane(newID) }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return newID
    }

    /// Adjust the nearest matching-axis split ratio around the focused pane.
    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = focusedPaneID else { return }
        splitRoot = splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
    }

    /// Remove a pane from the tree. Returns `.onlyPaneLeft` if the caller should
    /// close the whole tab (the pane was the last one), otherwise `.removed`.
    /// The pane's surface is destroyed in both cases.
    @discardableResult
    func removePane(_ paneID: UUID) -> PaneRemovalResult {
        guard let pane = splitRoot.findPane(id: paneID) else { return .notFound }
        pane.destroySurface()
        let panes = splitRoot.allPanes()
        if panes.count <= 1 {
            return .onlyPaneLeft
        }
        guard let newRoot = splitRoot.removing(paneID: paneID) else { return .notFound }
        splitRoot = newRoot
        paneFocusHistory.remove(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = nextFocusAfterClose()
        }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return .removed
    }
}

enum PaneRemovalResult {
    case removed
    case onlyPaneLeft
    case notFound
}

/// All tabs for one project.
@MainActor @Observable
final class Workspace: Identifiable {
    let projectID: UUID
    var tabs: [TerminalTab] = []
    var activeTabID: UUID?
    @ObservationIgnored
    private var tabHistory = RecencyStack<UUID>(limit: 50)

    var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    init(projectID: UUID, projectPath: String) {
        self.projectID = projectID
        let tab = TerminalTab(projectPath: projectPath)
        tabs.append(tab)
        activeTabID = tab.id
    }

    init(projectID: UUID, tabs: [TerminalTab], activeTabID: UUID?) {
        self.projectID = projectID
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    @discardableResult
    func createTab(projectPath: String) -> TerminalTab {
        let tab = TerminalTab(projectPath: projectPath)
        tabs.append(tab)
        if let current = activeTabID { tabHistory.push(current) }
        activeTabID = tab.id
        return tab
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        tabHistory.remove(tabID)
        guard activeTabID == tabID else { return }
        let valid = Set(tabs.map(\.id))
        if let prev = tabHistory.popValid(in: valid) {
            activeTabID = prev
        } else {
            activeTabID = tabs.last?.id
        }
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if let current = activeTabID, current != tabID { tabHistory.push(current) }
        activeTabID = tabID
    }

    func selectNextTab() {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        selectTab(tabs[(i + 1) % tabs.count].id)
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        selectTab(tabs[(i - 1 + tabs.count) % tabs.count].id)
    }

    /// Builds a recency-ordered list of tab IDs: current tab first, then most-recent-first from history.
    func recencyOrder() -> [UUID] {
        let valid = Set(tabs.map(\.id))
        var seen = Set<UUID>()
        var order: [UUID] = []
        if let active = activeTabID, valid.contains(active) {
            order.append(active)
            seen.insert(active)
        }
        for id in tabHistory.items where valid.contains(id) && seen.insert(id).inserted {
            order.append(id)
        }
        // Append any tabs not in history
        for tab in tabs where seen.insert(tab.id).inserted {
            order.append(tab.id)
        }
        return order
    }

    /// Switch to a tab without recording history (used during Ctrl+Tab cycling).
    func peekTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    func reorderTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }
}
