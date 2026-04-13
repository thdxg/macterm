import Foundation

/// A single tab — owns a split-pane tree.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    var customTitle: String?
    var splitRoot: SplitNode
    var focusedPaneID: UUID?

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
}

/// All tabs for one project.
@MainActor @Observable
final class Workspace: Identifiable {
    let projectID: UUID
    var tabs: [TerminalTab] = []
    var activeTabID: UUID?
    private var tabHistory: [UUID] = []

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
        if let current = activeTabID { tabHistory.append(current) }
        activeTabID = tab.id
        return tab
    }

    func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        tabHistory.removeAll { $0 == tabID }
        guard activeTabID == tabID else { return }
        let valid = Set(tabs.map(\.id))
        while let prev = tabHistory.popLast() {
            if valid.contains(prev) { activeTabID = prev
                return
            }
        }
        activeTabID = tabs.last?.id
    }

    func selectTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if let current = activeTabID, current != tabID { tabHistory.append(current) }
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
        for id in tabHistory.reversed() where valid.contains(id) && seen.insert(id).inserted {
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
