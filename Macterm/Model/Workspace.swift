import Foundation

/// A single tab — owns a split-pane tree.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    var customTitle: String?
    var splitRoot: SplitNode
    var focusedPaneID: UUID?
    /// When set, the split tree renders only this pane (zoom). The tree
    /// itself is untouched — clearing this restores the full layout.
    /// Transient: not persisted across launches.
    var zoomedPaneID: UUID?
    /// Most-recent-first stack of previously focused pane IDs
    /// (excludes the currently focused pane).
    @ObservationIgnored
    var paneFocusHistory = RecencyStack<UUID>(limit: 20)

    /// Record a focus change, pushing the previous pane onto history.
    func focusPane(_ paneID: UUID) {
        guard paneID != focusedPaneID else { return }
        if zoomedPaneID != nil, zoomedPaneID != paneID { zoomedPaneID = nil }
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

    var autoTitle: String {
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.sidebarSegmentTitle).joined(separator: " | ")
    }

    var sidebarTitle: String { customTitle ?? autoTitle }

    var executionState: TerminalExecutionState {
        let panes = splitRoot.allPanes()
        if panes.contains(where: { $0.executionState == .running }) { return .running }
        if panes.contains(where: { $0.executionState == .done }) { return .done }
        return .idle
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return nil }
        return splitRoot.findPane(id: focusedPaneID)
    }

    @discardableResult
    func acknowledgeCommandCompletion() -> Bool {
        var didAcknowledge = false
        for pane in splitRoot.allPanes() {
            didAcknowledge = pane.acknowledgeCommandCompletion() || didAcknowledge
        }
        return didAcknowledge
    }

    init(projectPath: String, projectID: UUID) {
        id = UUID()
        let pane = Pane(projectPath: projectPath, projectID: projectID)
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

    /// Toggle zoom for `paneID`. While zoomed, the tab renders only that pane;
    /// toggling off (or zooming a different pane) restores the full split view.
    func toggleZoom(paneID: UUID) {
        guard splitRoot.findPane(id: paneID) != nil else { return }
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = paneID
            focusPane(paneID)
        }
    }

    /// Split the focused pane (or a specific pane) in `direction`, placing the
    /// new pane in the `.second` position. Returns the new pane ID if created.
    @discardableResult
    func split(paneID: UUID, direction: SplitDirection) -> UUID? {
        let pane = splitRoot.findPane(id: paneID)
        // Inherit the source pane's cwd. Prefer the shell's OSC 7-reported pwd
        // (most accurate when shell integration is active), then fall back to
        // the foreground process's actual cwd read from the kernel (works
        // without shell integration / when a program holds the foreground),
        // and only then to the pane's original project path.
        let livePwd = pane.flatMap { p in p.nsView?.currentPwd ?? ProcessInspector.foregroundWorkingDirectory(forPane: p) }
        let sourcePath = livePwd ?? pane?.projectPath ?? NSHomeDirectory()
        let sourceProjectID = pane?.projectID ?? UUID()
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID, direction: direction, position: .second, projectPath: sourcePath, projectID: sourceProjectID
        )
        splitRoot = newRoot
        // Splitting reveals a new pane — exit zoom so it's visible.
        zoomedPaneID = nil
        if let newID { focusPane(newID) }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return newID
    }

    /// Split the focused pane along its longer on-screen axis (Ghostty's
    /// `new_split` / BSP behavior): a wide pane splits left/right, a tall pane
    /// splits top/bottom. Falls back to a horizontal split when the focused
    /// pane's NSView isn't attached yet and has no measurable bounds.
    @discardableResult
    func autoSplit(paneID: UUID) -> UUID? {
        let bounds = splitRoot.findPane(id: paneID)?.nsView?.bounds.size ?? .zero
        let direction: SplitDirection = bounds.height > bounds.width ? .vertical : .horizontal
        return split(paneID: paneID, direction: direction)
    }

    /// Adjust the nearest matching-axis split ratio around the focused pane.
    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = focusedPaneID else { return }
        splitRoot = splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
    }

    /// Move a pane next to another pane (drag-and-drop reorganization):
    /// detach it from its current spot — the tree collapses around it — and
    /// split the destination, placing the moved pane on the `zone` side. The
    /// `Pane` object is reused as-is, so its surface and shell are untouched.
    /// Returns false (tree unchanged) for a self-drop, a pane the tree doesn't
    /// contain, or the only pane in the tab.
    @discardableResult
    func movePane(_ paneID: UUID, onto destinationID: UUID, zone: PaneDropZone) -> Bool {
        guard paneID != destinationID,
              let pane = splitRoot.findPane(id: paneID),
              splitRoot.findPane(id: destinationID) != nil,
              let detached = splitRoot.removing(paneID: paneID)
        else { return false }
        let (newRoot, inserted) = detached.inserting(
            pane: pane, at: destinationID, direction: zone.splitDirection, position: zone.splitPosition
        )
        guard inserted else { return false }
        splitRoot = newRoot
        zoomedPaneID = nil
        focusPane(paneID)
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
        return true
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
        if zoomedPaneID == paneID { zoomedPaneID = nil }
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
    var activeTabID: UUID? {
        didSet {
            guard activeTabID != oldValue else { return }
            // Every selection path (select/peek/adopt/close) lands here — the
            // one funnel that wakes the adaptive foreground poll on tab switch.
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    @ObservationIgnored
    private var tabHistory = RecencyStack<UUID>(limit: 50)

    var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    init(projectID: UUID, projectPath: String) {
        self.projectID = projectID
        let tab = TerminalTab(projectPath: projectPath, projectID: projectID)
        tabs.append(tab)
        activeTabID = tab.id
    }

    init(projectID: UUID, tabs: [TerminalTab], activeTabID: UUID?) {
        self.projectID = projectID
        self.tabs = tabs
        // Validate the supplied activeTabID against the tabs list. A stale id
        // (e.g. from a corrupt persistence snapshot) falls back to the first
        // tab so we never end up with an "active tab" that doesn't exist.
        let validIDs = Set(tabs.map(\.id))
        if let activeTabID, validIDs.contains(activeTabID) {
            self.activeTabID = activeTabID
        } else {
            self.activeTabID = tabs.first?.id
        }
    }

    @discardableResult
    func createTab(projectPath: String) -> TerminalTab {
        let tab = TerminalTab(projectPath: projectPath, projectID: projectID)
        tabs.append(tab)
        if let current = activeTabID { tabHistory.push(current) }
        activeTabID = tab.id
        return tab
    }

    /// Append an existing tab — moved in from another workspace — and make it
    /// active. Unlike `createTab` the `TerminalTab` (and its live panes/surfaces)
    /// is reused as-is; the caller is responsible for having removed it from its
    /// previous workspace first.
    func adoptTab(_ tab: TerminalTab) {
        tabs.append(tab)
        if let current = activeTabID { tabHistory.push(current) }
        activeTabID = tab.id
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

    @discardableResult
    func selectTab(_ tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        if let current = activeTabID, current != tabID { tabHistory.push(current) }
        activeTabID = tabID
        return tab.acknowledgeCommandCompletion()
    }

    @discardableResult
    func selectNextTab() -> Bool {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return false }
        return selectTab(tabs[(i + 1) % tabs.count].id)
    }

    @discardableResult
    func selectPreviousTab() -> Bool {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return false }
        return selectTab(tabs[(i - 1 + tabs.count) % tabs.count].id)
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

    @discardableResult
    func selectTabByIndex(_ index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        return selectTab(tabs[index].id)
    }

    func reorderTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }
}
