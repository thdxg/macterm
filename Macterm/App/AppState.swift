import AppKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState")

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

    /// Re-reads each pane's foreground process so tab names track the running
    /// command (`hx`, `btop`, …). This polls like tmux's `automatic-rename`,
    /// rather than relying on terminal title escapes: with shell integration
    /// (Starship/ghostty) the OSC title is prompt/cwd churn, not the command,
    /// and a program may never emit a usable title at all (a layout-spawned or
    /// eager-warmed pane, a process that sets no title). A poll catches every
    /// case — manual launches, layout restores, quits — within one interval,
    /// regardless of titles.
    ///
    /// The cadence is adaptive (`PollCadence`): 250ms only while something is
    /// moving (recent tab switch / keystroke / OSC title / execution
    /// transition, or a running command with the app frontmost), 1s when the
    /// app is active but idle, 2s when inactive with a window still visible,
    /// and fully stopped when nothing is on screen. Each interesting moment
    /// fires `notePollEvent()`, which resumes instantly — so title liveness is
    /// event-bounded, not interval-bounded, and an idle app costs nothing.
    @ObservationIgnored
    private var pollTimer: Timer?

    @ObservationIgnored
    private var pollCadence = PollCadence()

    /// Whether the previous tick saw any `.running` pane; feeds
    /// `PollCadence.Context.isAnyPaneBusy` so a running command holds the
    /// fast cadence while the app is frontmost.
    @ObservationIgnored
    private var lastPollSawBusyPane = false

    @ObservationIgnored
    private var pollEventObservers: [Any] = []

    /// Injectable for tests (`PollCadence.Context` inputs). `NSApp` is nil
    /// while the SwiftUI `App` struct (and thus AppState) is constructed —
    /// before `NSApplicationMain` — so both closures must not force-unwrap:
    /// "no app yet" reads as inactive/invisible, which parks the poll until
    /// the first activation/occlusion event fires.
    @ObservationIgnored
    var isAppActive: () -> Bool = { NSApp?.isActive ?? false }

    /// Any on-screen window counts — including the quick terminal's
    /// non-activating panel. The surface incubator's window is ordered out and
    /// never becomes visible, so it never keeps polling alive.
    @ObservationIgnored
    var isAnyWindowVisible: () -> Bool = {
        (NSApp?.windows ?? []).contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Whether a pane's surface is occluded — its renderer parked by
    /// `ghostty_surface_set_occlusion`, so render/scrollbar heartbeats are
    /// suppressed and silence says nothing about completion. Injectable for
    /// tests. "No window" counts as occluded, which also covers panes
    /// incubated off-screen (the incubator window is never visible).
    @ObservationIgnored
    var paneIsOccluded: (Pane) -> Bool = { pane in
        !(pane.nsView?.window?.occlusionState.contains(.visible) ?? false)
    }

    /// Panes that were occluded on the previous poll tick, so the visible
    /// transition can restart their quiet window before settling resumes.
    @ObservationIgnored
    private var previouslyOccludedPanes: Set<UUID> = []

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

        let center = NotificationCenter.default
        let onEvent: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.notePollEvent() }
        }
        pollEventObservers = [
            center.addObserver(forName: .terminalPollEvent, object: nil, queue: .main, using: onEvent),
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: onEvent
            ),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: onEvent
            ),
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: onEvent
            ),
            // Wake is on NSWorkspace's own center, not the default one. A
            // timer whose fire date passed during sleep also fires once on
            // wake; `noteEvent` coalescing absorbs the double tick.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onEvent
            ),
        ]
        pollNow()
    }

    // MARK: - Poll scheduling

    /// An instant-resume trigger for the poll (see `PollCadence.noteEvent`).
    func notePollEvent() {
        if pollCadence.noteEvent(at: Date()) {
            pollNow()
        } else {
            // Coalesced — but the mode may still have shortened (idle → fast
            // right after a tick), so re-arm at the new cadence.
            reschedulePoll()
        }
    }

    private func pollNow() {
        // Before the work: the refresh publishes execution-state transitions
        // that fire `notePollEvent`, and the fresh poll timestamp turns those
        // into coalesced no-ops instead of recursive polls.
        pollCadence.notePolled(at: Date())
        refreshAllForegroundProcesses()
        reschedulePoll()
    }

    private func reschedulePoll() {
        pollTimer?.invalidate()
        pollTimer = nil
        let context = PollCadence.Context(
            isAppActive: isAppActive(),
            isAnyWindowVisible: isAnyWindowVisible(),
            isAnyPaneBusy: lastPollSawBusyPane
        )
        guard let delay = pollCadence.nextDelay(at: Date(), context: context) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        timer.tolerance = delay * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Re-read the foreground process name of every live pane across all
    /// workspaces. Each pane only republishes (and triggers a tab re-render)
    /// when its name actually changes, so this is cheap when nothing's moving.
    func refreshAllForegroundProcesses() {
        // Shell/raw-mode detection (KERN_PROCARGS2 + open/tcgetattr per pane)
        // and the quiet-settle only matter when the status indicator is shown;
        // skip them in icon mode so the default poll stays as cheap as before
        // this feature.
        let trackExecution = Preferences.shared.showTabStatusIndicator
        var didAcknowledgeCompletion = false
        var seenPanes: Set<UUID> = []
        var sawBusyPane = false
        for (projectID, ws) in workspaces {
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() {
                    seenPanes.insert(pane.id)
                    pane.refreshForegroundProcess(trackExecution: trackExecution)
                    if trackExecution {
                        settleIfVisible(pane)
                    }
                    if pane.executionState == .running { sawBusyPane = true }
                    didAcknowledgeCompletion = acknowledgeFinishedCommandIfActive(
                        paneID: pane.id,
                        projectID: projectID,
                        saveImmediately: false
                    ) || didAcknowledgeCompletion
                }
            }
        }
        previouslyOccludedPanes.formIntersection(seenPanes)
        lastPollSawBusyPane = sawBusyPane
        if didAcknowledgeCompletion { saveWorkspaces() }
    }

    /// Quiet-settle only while the surface actually renders: an occluded pane
    /// emits no activity heartbeats (its renderer is parked), so settling it
    /// would misread suppressed output as completion. On the occluded→visible
    /// edge the quiet window restarts, giving a still-running program time to
    /// deliver heartbeats again before the settle can fire.
    ///
    /// Not private so tests can drive the guard directly (`paneIsOccluded` is
    /// injectable) without a live surface or mutating the `Preferences`
    /// singleton the poll reads.
    func settleIfVisible(_ pane: Pane) {
        if paneIsOccluded(pane) {
            previouslyOccludedPanes.insert(pane.id)
            return
        }
        if previouslyOccludedPanes.remove(pane.id) != nil {
            pane.refreshTerminalActivityWindow()
        }
        pane.settleTerminalActivityIfQuiet()
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
        logger.info("restoreSelection: \(projects.count, privacy: .public) projects")
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
            acknowledgeActiveTab(projectID: id)
            warmFocusedProject()
        }
    }

    func saveWorkspaces() {
        workspaceStore.save(WorkspaceSerializer.snapshot(workspaces))
    }

    // MARK: - Project

    func selectProject(_ project: Project) {
        logger.debug("selectProject: \(project.name, privacy: .public)")
        activeProjectID = project.id
        recordProjectVisit(project.id)
        autoApplyLayoutOnFirstOpen(project)
        ensureWorkspace(projectID: project.id, path: project.path)
        acknowledgeActiveTab(projectID: project.id)
        warmFocusedProject()
        // Creating a workspace doesn't change any tab selection (the poll's
        // usual wake signal), so bump it directly.
        notePollEvent()
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

    /// Whether any pane in the project's workspace has a live terminal view —
    /// i.e. there's something for `unloadProject(_:)` to tear down.
    func isProjectLoaded(_ projectID: UUID) -> Bool {
        guard let ws = workspaces[projectID] else { return false }
        return ws.tabs.flatMap { $0.splitRoot.allPanes() }.contains { $0.nsView != nil }
    }

    /// Tear down a project's terminal surfaces (ending their shell processes)
    /// while keeping its tab/split layout — returning it to the lazy state an
    /// unfocused project is in right after launch, where the workspace exists
    /// in memory but no pane spawns a shell until the project is selected
    /// again. Implemented as the same snapshot → restore round-trip a
    /// quit/relaunch performs, so each pane's live cwd is captured before its
    /// surface dies. Unloading the active project deselects it; leaving it
    /// active would let SwiftUI respawn the shells immediately.
    func unloadProject(_ projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        logger.debug("unloadProject: \(projectID, privacy: .public)")
        let snapshot = WorkspaceSerializer.snapshot([projectID: ws])
        for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
            pane.destroySurface()
        }
        if let restored = WorkspaceSerializer.restore(from: snapshot, validIDs: [projectID]).first {
            workspaces[projectID] = restored
        }
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    func removeProject(_ projectID: UUID) {
        logger.debug("removeProject: \(projectID, privacy: .public)")
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
        logger.debug("createTab: project=\(projectID, privacy: .public) tabs=\(ws.tabs.count, privacy: .public)")
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
        logger.debug("closeTab: \(tabID, privacy: .public) project=\(projectID, privacy: .public)")
        for pane in tab.splitRoot.allPanes() {
            pane.destroySurface()
        }
        ws.closeTab(tabID)
        saveWorkspaces()
    }

    func selectTab(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        let didAcknowledgeCompletion = ws.selectTab(tabID)
        if ws.activeTabID != before || didAcknowledgeCompletion {
            saveWorkspaces()
        }
    }

    /// Move a tab — with its live panes and running shells intact — from one
    /// project's workspace into another's. The `TerminalTab` object is reused
    /// as-is, so its surfaces stay valid (both workspaces live in the same
    /// window). The destination becomes the active project with the moved tab
    /// selected, so the user lands where they meant to be. No-op for a
    /// same-project move or an unknown source/tab.
    func moveTab(_ tabID: UUID, from sourceProjectID: UUID, to destProjectID: UUID, destPath: String) {
        guard sourceProjectID != destProjectID,
              let source = workspaces[sourceProjectID],
              let tab = source.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.debug(
            "moveTab: \(tabID, privacy: .public) from=\(sourceProjectID, privacy: .public) to=\(destProjectID, privacy: .public)"
        )
        ensureWorkspace(projectID: destProjectID, path: destPath)
        guard let dest = workspaces[destProjectID] else { return }
        source.closeTab(tabID)
        dest.adoptTab(tab)
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    func selectNextTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        let didAcknowledgeCompletion = ws.selectNextTab()
        if ws.activeTabID != before || didAcknowledgeCompletion {
            saveWorkspaces()
        }
    }

    func selectPreviousTab(projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        let didAcknowledgeCompletion = ws.selectPreviousTab()
        if ws.activeTabID != before || didAcknowledgeCompletion {
            saveWorkspaces()
        }
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
        let beforeProjectID = activeProjectID
        let beforeTabID = workspaces[project.id]?.activeTabID

        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
        let didAcknowledgeCompletion = workspaces[project.id]?.selectTab(tab.id) ?? false
        if activeProjectID != beforeProjectID
            || workspaces[project.id]?.activeTabID != beforeTabID
            || didAcknowledgeCompletion
        {
            saveWorkspaces()
        }
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        let didAcknowledgeCompletion = ws.selectTabByIndex(index)
        if ws.activeTabID != before || didAcknowledgeCompletion {
            saveWorkspaces()
        }
    }

    // MARK: - Splits

    func splitPane(direction: SplitDirection, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab,
              let paneID = tab.focusedPaneID
        else { return }
        logger.debug("splitPane: \(String(describing: direction), privacy: .public) pane=\(paneID, privacy: .public)")
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
        logger.debug("closePane: \(paneID, privacy: .public) project=\(projectID, privacy: .public)")
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
        logger.info("applyLayout: project=\(projectName, privacy: .public)")
        let file: LayoutFile
        do {
            file = try LayoutFile.load(fromProjectRoot: projectRoot)
        } catch {
            logger.error("applyLayout failed to load: \(error, privacy: .public)")
            return error
        }
        let plan = LayoutReconciler.plan(
            layout: file,
            workspace: workspaces[projectID],
            projectRoot: projectRoot,
            projectID: projectID
        )
        let planDesc = "tabs=\(plan.tabs.count) destroy=\(plan.panesToDestroy.count) closeTabs=\(plan.tabsToClose.count)"
        logger.info("applyLayout plan: \(planDesc, privacy: .public)")
        // The file names a different project than the one we're applying to.
        // Optional in the format, so only flag when present and mismatched.
        let mismatchedName: String? = {
            guard let saved = file.name, saved != projectName else { return nil }
            return saved
        }()
        // Confirm if applying would destroy panes OR the project name mismatches.
        if plan.isDestructive || mismatchedName != nil {
            logger.info("applyLayout: staged for confirmation, mismatch=\(mismatchedName ?? "none", privacy: .public)")
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
        logger.info("saveLayout: project=\(projectName, privacy: .public)")
        guard let ws = workspaces[projectID] else { return nil }
        do {
            try LayoutSerializer.write(ws, projectName: projectName, projectRoot: projectRoot)
            logger.info("saveLayout succeeded: tabs=\(ws.tabs.count, privacy: .public)")
            return nil
        } catch {
            logger.error("saveLayout failed: \(error, privacy: .public)")
            return error
        }
    }

    /// Swap each tab's tree to the reconciled shape, reusing the live `Pane`
    /// objects the plan kept (surfaces preserved) and destroying the rest.
    private func executeLayoutPlan(_ plan: LayoutReconciler.Plan, projectID: UUID) {
        logger
            .info("executeLayoutPlan: tabs=\(plan.tabs.count, privacy: .public) destroying=\(plan.panesToDestroy.count, privacy: .public)")
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
            let beforeTabID = workspaces[projectID]?.activeTabID
            let beforeFocusedPaneID = tab.focusedPaneID
            let didAcknowledgeCompletion = workspaces[projectID]?.selectTab(tab.id) ?? false
            tab.focusPane(paneID)
            if workspaces[projectID]?.activeTabID != beforeTabID
                || tab.focusedPaneID != beforeFocusedPaneID
                || didAcknowledgeCompletion
            {
                saveWorkspaces()
            }
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

    /// Cycle focus through the active tab's panes in tree order, wrapping at
    /// the ends. `forward` moves to the next pane; otherwise the previous.
    func cyclePane(forward: Bool, projectID: UUID) {
        guard let tab = workspaces[projectID]?.activeTab else { return }
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1 else { return }
        let current = tab.focusedPaneID.flatMap { id in panes.firstIndex(where: { $0.id == id }) } ?? 0
        let step = forward ? 1 : -1
        let next = panes[(current + step + panes.count) % panes.count]
        tab.focusPane(next.id)
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

    @discardableResult
    private func acknowledgeActiveTab(projectID: UUID, saveImmediately: Bool = true) -> Bool {
        guard projectID == activeProjectID,
              let tab = workspaces[projectID]?.activeTab
        else { return false }
        let didAcknowledgeCompletion = tab.acknowledgeCommandCompletion()
        if didAcknowledgeCompletion, saveImmediately {
            saveWorkspaces()
        }
        return didAcknowledgeCompletion
    }

    @discardableResult
    func acknowledgeFinishedCommandIfActive(
        paneID: UUID,
        projectID: UUID,
        saveImmediately: Bool = true
    ) -> Bool {
        // The sidebar shows the *entire* active tab as idle (displayState masks
        // `.done` for the tab the user is looking at), so every pane in that tab
        // must actually be cleared — not just the focused one. Otherwise a
        // non-focused split pane that finished a command stays `.done` under the
        // hood, gets persisted, and reappears as a checkmark after restart even
        // though the user saw an empty circle.
        guard NSApp.isActive,
              projectID == activeProjectID,
              let tab = workspaces[projectID]?.activeTab,
              tab.splitRoot.findPane(id: paneID) != nil
        else { return false }
        return acknowledgeActiveTab(projectID: projectID, saveImmediately: saveImmediately)
    }

    // MARK: - Private

    private func ensureWorkspace(projectID: UUID, path: String) {
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, projectPath: path)
        }
    }
}
