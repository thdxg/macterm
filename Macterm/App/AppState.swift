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
    /// A computed layout-apply plan awaiting user confirmation because applying
    /// it would terminate one or more live panes/tabs. nil when no apply is
    /// pending (or the pending apply is non-destructive and already ran).
    var pendingLayoutApply: PendingLayoutApply?
    var isCommandPaletteVisible = false
    /// The command palette's search text, kept on `AppState` so it survives the
    /// panel's view lifecycle — closing and reopening the palette preserves what
    /// was typed.
    var commandPaletteQuery = ""
    var postPaletteAction: (() -> Void)?
    var renamingTabID: UUID?
    var renamingProjectID: UUID?
    private(set) var hasRestoredSelection = false

    /// Most-recent-first stack of project IDs. Persisted to UserDefaults.
    @ObservationIgnored
    private var projectRecency = RecencyStack<UUID>(limit: 50)
    private let recencyKey = "macterm.projectRecency"

    struct PendingClosePane: Equatable {
        let paneID: UUID
        let projectID: UUID
    }

    /// A reconcile plan staged for confirmation — because applying it would
    /// close panes / end their processes, and/or the file names a different
    /// project than the active one.
    struct PendingLayoutApply {
        let projectID: UUID
        let plan: LayoutReconciler.Plan
        /// The project name the file was saved for, when it differs from the
        /// active project; nil when names match (or the file omits one).
        let mismatchedProjectName: String?
        /// The active project's name, for the mismatch message.
        let currentProjectName: String

        /// The confirmation dialog body, combining the reasons this apply needs
        /// confirming (project-name mismatch and/or pane destruction).
        var confirmationMessage: String {
            var parts: [String] = []
            if let saved = mismatchedProjectName {
                parts.append("This layout was saved for “\(saved)”, but you're applying it to “\(currentProjectName)”.")
            }
            if plan.isDestructive {
                parts.append("Applying it will close some panes and end the processes running in them.")
            }
            return parts.joined(separator: "\n\n")
        }
    }

    // Tab cycling state (Ctrl+Tab)
    private var tabCycleOrder: [UUID] = []
    private var tabCycleIndex: Int = 0
    var isTabCycling: Bool { !tabCycleOrder.isEmpty }

    private let workspaceStore: WorkspaceStore
    private var autoTileObserver: Any?

    /// Periodically re-reads each pane's foreground process so tab names track
    /// the running command (`hx`, `btop`, …). This polls like tmux's
    /// `automatic-rename`, rather than relying on terminal title escapes: with
    /// shell integration (Starship/ghostty) the OSC title is prompt/cwd churn,
    /// not the command, and a program may never emit a usable title at all (a
    /// layout-spawned or eager-warmed pane, a process that sets no title). A
    /// poll catches every case — manual launches, layout restores, quits —
    /// within one interval, regardless of titles.
    ///
    /// The interval (250ms) is a responsiveness choice, not a cost one: it's a
    /// run-loop timer (the thread parks between ticks, no busy-loop), and each
    /// tick is one `proc_pidinfo` per pane — ~0.24µs/call, so even 20 panes
    /// 4×/sec is ~0.002% of a core. A pane only republishes (→ re-render) when
    /// its name actually changes, so idle panes are free.
    @ObservationIgnored
    private var processNameTimer: Timer?

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

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllForegroundProcesses() }
        }
        RunLoop.main.add(timer, forMode: .common)
        processNameTimer = timer
    }

    /// Re-read the foreground process name of every live pane across all
    /// workspaces. Each pane only republishes (and triggers a tab re-render)
    /// when its name actually changes, so this is cheap when nothing's moving.
    func refreshAllForegroundProcesses() {
        for ws in workspaces.values {
            for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
                pane.refreshForegroundProcess()
            }
        }
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
        // A committed layout file is the source of truth: skip restoring the
        // session snapshot for any project that has one, leaving its workspace
        // nil so it rebuilds from `.macterm/layout.yaml` on open (below / on
        // first select). Projects with no layout file restore their snapshot.
        let pathByID = Dictionary(projects.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        for ws in WorkspaceSerializer.restore(from: snapshots, validIDs: valid)
            where !LayoutFile.exists(atProjectRoot: pathByID[ws.projectID] ?? "")
        {
            workspaces[ws.projectID] = ws
        }
        if let id = Preferences.shared.activeProjectID,
           let project = projects.first(where: { $0.id == id })
        {
            activeProjectID = id
            recordProjectVisit(id)
            // Build the active project from its layout file if it has one (its
            // snapshot was skipped above); otherwise the restored snapshot stands
            // and `ensureWorkspace` only creates a default when neither exists.
            autoApplyLayoutOnFirstOpen(project)
            ensureWorkspace(projectID: id, path: project.path)
            warmFocusedProject()
        }
    }

    func saveWorkspaces() {
        workspaceStore.save(WorkspaceSerializer.snapshot(workspaces))
    }

    // MARK: - Project

    func selectProject(_ project: Project) {
        activeProjectID = project.id
        recordProjectVisit(project.id)
        autoApplyLayoutOnFirstOpen(project)
        ensureWorkspace(projectID: project.id, path: project.path)
        warmFocusedProject()
    }

    /// Start the shells for every tab of the focused project, not just the
    /// active one — so a multi-tab project (e.g. from a declarative layout) has
    /// all its processes running on open. Other projects stay lazy. The active
    /// tab is created by SwiftUI as usual; the rest are warmed off-screen via
    /// `SurfaceIncubator`. No-op when the toggle is off.
    func warmFocusedProject() {
        guard Preferences.shared.eagerlyStartProjectTabs,
              let projectID = activeProjectID,
              let ws = workspaces[projectID]
        else { return }
        for pane in Self.panesToWarm(in: ws) {
            SurfaceIncubator.shared.warm(pane)
        }
    }

    /// Panes whose shells should be eagerly started: every pane in every tab
    /// except the active tab (SwiftUI starts the active tab's panes when it
    /// renders them). Pure, so it's unit-testable without surfaces.
    static func panesToWarm(in workspace: Workspace) -> [Pane] {
        workspace.tabs
            .filter { $0.id != workspace.activeTabID }
            .flatMap { $0.splitRoot.allPanes() }
    }

    /// On a project's first open this session (no live/restored workspace yet),
    /// build its workspace from `.macterm/layout.yaml` if present. Because there
    /// are no live panes, the apply is pure-spawn — never destructive, never
    /// prompts. A restored snapshot already populates `workspaces`, so it takes
    /// precedence; if there's no layout file this no-ops and `ensureWorkspace`
    /// creates the default single-pane workspace.
    private func autoApplyLayoutOnFirstOpen(_ project: Project) {
        guard workspaces[project.id] == nil,
              LayoutFile.exists(atProjectRoot: project.path)
        else { return }
        applyLayout(projectID: project.id, projectName: project.name, projectRoot: project.path)
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

    /// Update the active project's path to wherever the focused pane currently
    /// sits (via OSC 7 — `pane.nsView.currentPwd`). Useful when a project
    /// started in one directory but the user has settled into a subdirectory
    /// and wants new tabs / persisted state to start there.
    ///
    /// No-op when there's no active project or no resolvable pwd. We don't
    /// touch open panes or workspaces — those keep their current cwd; only
    /// future tabs created via `createTab(projectID:projects:)` (which reads
    /// `project.path`) will land in the new directory.
    func replaceProjectPathWithCurrentDir(projectStore: ProjectStore) {
        guard let projectID = activeProjectID,
              let pane = focusedPane(for: projectID),
              let pwd = pane.nsView?.currentPwd,
              !pwd.isEmpty
        else { return }
        projectStore.setPath(id: projectID, to: pwd)
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

    /// Split the focused pane along its longer on-screen axis (Ghostty's
    /// `new_split` / BSP behavior). Direction is decided by `TerminalTab.autoSplit`.
    func autoSplitPane(projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        tab.autoSplit(paneID: paneID)
        saveWorkspaces()
    }

    func resizePane(_ direction: PaneFocusDirection, projectID: UUID, delta: CGFloat = 0.03) {
        workspaces[projectID]?.activeTab?.resize(direction, delta: delta)
        saveWorkspaces()
    }

    func toggleZoom(projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        tab.toggleZoom(paneID: paneID)
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

    // MARK: - Layout files

    /// Apply a project's declarative layout to its live workspace, reconciling
    /// with minimal destruction (see `LayoutReconciler`). A non-destructive
    /// reconcile (only spawns + resizes) runs immediately; one that would
    /// terminate panes/tabs is staged in `pendingLayoutApply` for confirmation.
    /// Returns an error to surface if the file is missing or unparseable.
    @discardableResult
    func applyLayout(projectID: UUID, projectName: String, projectRoot: String) -> Error? {
        let file: LayoutFile
        do {
            file = try LayoutFile.load(fromProjectRoot: projectRoot)
        } catch {
            return error
        }
        let plan = LayoutReconciler.plan(
            layout: file,
            workspace: workspaces[projectID],
            projectRoot: projectRoot,
            projectID: projectID
        )
        // The file names a different project than the one we're applying to.
        // Optional in the format, so only flag when present and mismatched.
        let mismatchedName: String? = {
            guard let saved = file.name, saved != projectName else { return nil }
            return saved
        }()
        // Confirm if applying would destroy panes OR the project name mismatches.
        if plan.isDestructive || mismatchedName != nil {
            pendingLayoutApply = PendingLayoutApply(
                projectID: projectID,
                plan: plan,
                mismatchedProjectName: mismatchedName,
                currentProjectName: projectName
            )
        } else {
            executeLayoutPlan(plan, projectID: projectID)
        }
        return nil
    }

    func confirmPendingLayoutApply() {
        guard let pending = pendingLayoutApply else { return }
        pendingLayoutApply = nil
        executeLayoutPlan(pending.plan, projectID: pending.projectID)
    }

    func cancelPendingLayoutApply() {
        pendingLayoutApply = nil
    }

    /// Save the active project's live workspace to its `.macterm/layout.yaml`.
    @discardableResult
    func saveLayout(projectID: UUID, projectName: String, projectRoot: String) -> Error? {
        guard let ws = workspaces[projectID] else { return nil }
        do {
            try LayoutSerializer.write(ws, projectName: projectName, projectRoot: projectRoot)
            return nil
        } catch {
            return error
        }
    }

    /// Swap each tab's tree to the reconciled shape, reusing the live `Pane`
    /// objects the plan kept (surfaces preserved) and destroying the rest.
    private func executeLayoutPlan(_ plan: LayoutReconciler.Plan, projectID: UUID) {
        let existing = workspaces[projectID]?.tabs ?? []
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var newTabs: [TerminalTab] = []
        for planned in plan.tabs {
            if let id = planned.existingTabID, let tab = byID[id] {
                // Reuse the tab object (preserves its id/history); swap the tree.
                tab.splitRoot = planned.root
                tab.focusedPaneID = planned.focusedPaneID
                tab.customTitle = planned.title
                newTabs.append(tab)
            } else {
                newTabs.append(TerminalTab(
                    id: UUID(),
                    splitRoot: planned.root,
                    focusedPaneID: planned.focusedPaneID,
                    customTitle: planned.title
                ))
            }
        }

        // Destroy surfaces only AFTER the new trees no longer reference them.
        for pane in plan.panesToDestroy {
            pane.destroySurface()
        }

        let activeTabID = newTabs.first?.id
        if let ws = workspaces[projectID] {
            ws.tabs = newTabs
            ws.activeTabID = activeTabID
        } else {
            workspaces[projectID] = Workspace(projectID: projectID, tabs: newTabs, activeTabID: activeTabID)
        }
        activeProjectID = projectID
        saveWorkspaces()

        // Focus the declared/active pane once its surface attaches to a window.
        if let tab = newTabs.first, let paneID = tab.focusedPaneID {
            FocusRestoration.restoreFocus(
                to: paneID,
                in: tab.splitRoot,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        // Start the non-active tabs' processes too, so an applied multi-tab
        // layout runs everything it declares, not just the active tab.
        warmFocusedProject()
    }

    func focusPane(_ paneID: UUID, projectID: UUID) {
        workspaces[projectID]?.activeTab?.focusPane(paneID)
    }

    func navigateToPane(_ paneID: UUID, projectID: UUID) {
        guard workspaces[projectID] != nil else {
            NSApp.activate()
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.reopenIfNeeded()
            }
            return
        }
        activeProjectID = projectID
        recordProjectVisit(projectID)
        if let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
            workspaces[projectID]?.selectTab(tab.id)
            tab.focusPane(paneID)
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.reopenIfNeeded()
        }
        NSApp.activate()
        if let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            DispatchQueue.main.async {
                FocusRestoration.restoreFocus(to: paneID, in: tab.splitRoot, window: window)
            }
        }
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

    // MARK: - Focus

    func restoreFocusToActivePane() {
        guard let projectID = activeProjectID,
              let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        FocusRestoration.restoreFocus(
            to: paneID,
            in: tab.splitRoot,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    // MARK: - Private

    private func ensureWorkspace(projectID: UUID, path: String) {
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, projectPath: path)
        }
    }
}
