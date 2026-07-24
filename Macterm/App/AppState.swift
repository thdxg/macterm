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

    /// A tab close staged for confirmation because one of its panes has a
    /// running foreground program (closing kills the pane's zmx session — the
    /// destructive act now that quit detaches).
    struct PendingCloseTab: Equatable {
        let tabID: UUID
        let projectID: UUID
    }

    var pendingCloseTab: PendingCloseTab?

    /// A project removal staged for confirmation, same busy rule as tabs.
    /// Carries the full removal (AppState workspace + ProjectStore entry) as
    /// a closure, since the store lives with the caller.
    struct PendingRemoveProject {
        let projectID: UUID
        let completeRemoval: () -> Void
    }

    var pendingRemoveProject: PendingRemoveProject?

    /// A reconcile plan staged for confirmation because applying it would
    /// close panes / end their processes. (There's no name-mismatch prompt
    /// anymore: central project files are matched by *path*, so a differing
    /// `name:` only means the project was renamed since the last save —
    /// expected drift, not a wrong-file hazard.)
    struct PendingLayoutApply {
        let projectID: UUID
        let plan: LayoutReconciler.Plan

        var confirmationMessage: String {
            "Applying this layout will close some panes and end the processes running in them."
        }
    }

    /// A layout apply/save/import notice awaiting presentation (alert in
    /// `MactermApp`). Fed by the explicit palette/menu commands and by the
    /// silent first-open auto-apply — an invalid project file must always
    /// surface a dialog, never fail silently.
    struct LayoutError: Identifiable {
        let id = UUID()
        /// "apply" / "save" / "import" — slotted into the default alert title.
        let verb: String
        let message: String
        /// Title override for notices that aren't failures (e.g. a save that
        /// landed but is shadowed by a duplicate file).
        var customTitle: String?
        var title: String { customTitle ?? "Couldn't \(verb) layout" }
    }

    var pendingLayoutError: LayoutError?

    /// Presents the "New Remote Project" sheet (#104) — set by the palette
    /// command and the sidebar's New Project menu, consumed by `MainWindow`.
    var isNewRemoteProjectSheetPresented = false

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
    /// The delay `pollTimer` was scheduled with, so `reschedulePoll` can skip
    /// tearing down and rebuilding an identical timer — `.terminalPollEvent`
    /// fires often under a busy workload (every keystroke, output transition,
    /// OSC title), and each fire recomputed the same cadence and churned a new
    /// `Timer` + RunLoop registration for no behavior change.
    @ObservationIgnored
    private var pollTimerDelay: TimeInterval?

    @ObservationIgnored
    private var pollCadence = PollCadence()

    /// Whether the previous tick saw any `.running` pane; feeds
    /// `PollCadence.Context.isAnyPaneBusy` so a running command holds the
    /// fast cadence while the app is frontmost.
    @ObservationIgnored
    private var lastPollSawBusyPane = false

    @ObservationIgnored
    private var pollEventObservers: [Any] = []

    /// Every block-based observer token paired with the center it was added to,
    /// so `deinit` can remove them from the correct center. `nonisolated(unsafe)`
    /// so the nonisolated deinit can read it — the object is being destroyed, so
    /// there is no concurrent access. Tokens are `NSObjectProtocol` (what
    /// `addObserver(forName:…)` returns).
    nonisolated(unsafe) private var observerTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

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

    /// zmx session-persistence client. Injectable so tests can observe
    /// session kills without a real daemon.
    @ObservationIgnored
    var zmx: ZmxClient = .live

    /// Refresh policy for `ZmxForegroundResolver`'s name→leader-pid cache:
    /// refresh on session lifecycle events plus a 30s reconcile TTL — never
    /// per tick (`zmx ls` is a fork/exec).
    @ObservationIgnored
    private var zmxRefreshGate = ZmxRefreshGate()

    /// Tier-2 remote tab naming (#104): batched per-host ssh probes on their
    /// own throttled cadence, decoupled from the local poll's 250ms bursts.
    /// The probe closure is handed in per refresh so it always reads the
    /// injectable `zmx` (tests swap `zmx` after init).
    @ObservationIgnored
    private let remoteForegroundResolver = RemoteForegroundResolver()

    /// Drops overlapping `zmx ls` refreshes so a slow probe can't pile up
    /// behind the poll.
    @ObservationIgnored
    private var zmxRefreshInFlight = false

    /// Bounded retries while a *wrapped* pane is missing from `zmx ls`: a
    /// freshly-spawned session registers asynchronously, so the refresh fired
    /// by its creation event usually runs too early. Reset on every lifecycle
    /// event; without the cap, a genuinely dead daemon would turn every poll
    /// tick back into a fork/exec.
    @ObservationIgnored
    private var zmxRetryBudget = 8

    /// Central project-file store (`~/.config/macterm/projects`). Injectable
    /// so tests never read or write the user's real directory.
    @ObservationIgnored
    let projectFiles: ProjectFileStore

    init(
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        projectFiles: ProjectFileStore = ProjectFileStore()
    ) {
        self.workspaceStore = workspaceStore
        self.projectFiles = projectFiles
        let autoTileToken = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
        autoTileObserver = autoTileToken
        observerTokens.append((NotificationCenter.default, autoTileToken))
        let restored = (Preferences.defaults.stringArray(forKey: recencyKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        projectRecency = RecencyStack<UUID>(limit: 50, items: restored)

        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let onEvent: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.notePollEvent() }
        }
        let tokens: [(NotificationCenter, NSObjectProtocol)] = [
            (center, center.addObserver(forName: .terminalPollEvent, object: nil, queue: .main, using: onEvent)),
            (center, center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: onEvent
            )),
            (center, center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: onEvent
            )),
            (center, center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: onEvent
            )),
            // Wake is on NSWorkspace's own center, not the default one. A
            // timer whose fire date passed during sleep also fires once on
            // wake; `noteEvent` coalescing absorbs the double tick.
            (workspaceCenter, workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onEvent
            )),
            (center, center.addObserver(
                forName: .zmxSessionsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.zmxRefreshGate.noteSessionLifecycle()
                    self?.zmxRetryBudget = 8
                    self?.notePollEvent()
                }
            }),
        ]
        pollEventObservers = tokens.map(\.1)
        observerTokens.append(contentsOf: tokens.map { (center: $0.0, token: $0.1) })
        pollNow()
    }

    deinit {
        // Remove every block-based observer from the center each was added to.
        // Production runs one app-lifetime instance, but tests build fresh
        // AppStates — without this, their observers accumulate on the shared
        // centers and dead instances' blocks keep firing into a nil weak self.
        // Only nonisolated-safe calls here (observerTokens is nonisolated).
        // The poll timer self-cleans: it's non-repeating with a `[weak self]`
        // closure, so a dead instance's timer fires once into nil and stops.
        for entry in observerTokens {
            entry.center.removeObserver(entry.token)
        }
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
        refreshZmxCacheIfDue()
        refreshAllForegroundProcesses()
        reschedulePoll()
    }

    /// Refresh `ZmxForegroundResolver`'s name→leader-pid cache when the gate
    /// says so (session lifecycle event, or the 30s reconcile TTL). Runs the
    /// `zmx ls` subprocess off-main; per-tick foreground resolution reads the
    /// cache with cheap syscalls only. Steady state: at most one fork/exec
    /// every 30s, zero while polling is paused.
    private func refreshZmxCacheIfDue() {
        guard !zmxRefreshInFlight, zmx.isBundled() else { return }
        guard zmxRefreshGate.shouldRefresh(now: Date()) else { return }
        zmxRefreshInFlight = true
        Task { [weak self, zmx] in
            let map = await zmx.sessionLeaderPIDs()
            ZmxForegroundResolver.updateCache(map)
            await MainActor.run { self?.finishZmxRefresh(map: map) }
        }
    }

    private func finishZmxRefresh(map: [String: pid_t]) {
        zmxRefreshInFlight = false
        // A wrapped pane absent from the listing means the refresh raced the
        // session's async registration — retry on the next tick (bounded).
        // Without this, the tab title reads `zmx` (the attach client) until
        // the 30s reconcile catches up.
        let missingWrapped = workspaces.values
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
            .contains { $0.nsView?.isZmxWrapped == true && map[$0.sessionName] == nil }
        if missingWrapped, zmxRetryBudget > 0 {
            zmxRetryBudget -= 1
            zmxRefreshGate.noteSessionLifecycle()
            notePollEvent()
        }
    }

    private func reschedulePoll() {
        let context = PollCadence.Context(
            isAppActive: isAppActive(),
            isAnyWindowVisible: isAnyWindowVisible(),
            isAnyPaneBusy: lastPollSawBusyPane
        )
        guard let delay = pollCadence.nextDelay(at: Date(), context: context) else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerDelay = nil
            return
        }
        // A running timer with the same cadence needs no change — rebuilding it
        // (invalidate + new Timer + RunLoop.add) on every `.terminalPollEvent`
        // is pure churn under a busy workload. Only rebuild when the delay
        // actually changed (or no timer is scheduled). The one-shot timer
        // clears `pollTimer` when it fires, so a nil timer here always rebuilds.
        if let existing = pollTimer, existing.isValid, pollTimerDelay == delay { return }
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        timer.tolerance = delay * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerDelay = delay
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
        var activeRemotePanes: [Pane] = []
        for (projectID, ws) in workspaces {
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() {
                    seenPanes.insert(pane.id)
                    if pane.isRemote {
                        // The local process table only knows `ssh` here — a
                        // local refresh would stomp the probe-derived name
                        // and instantly expire remote OSC titles. Execution
                        // state still settles from output heartbeats, and
                        // the frontmost project's panes feed the throttled
                        // remote probe below.
                        if projectID == activeProjectID {
                            activeRemotePanes.append(pane)
                        }
                    } else {
                        pane.refreshForegroundProcess(trackExecution: trackExecution)
                    }
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
        if !activeRemotePanes.isEmpty, isAnyWindowVisible() {
            remoteForegroundResolver.refresh(panes: activeRemotePanes, probe: zmx.remoteForegroundComms)
        }
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
        Preferences.defaults.set(projectRecency.items.map(\.uuidString), forKey: recencyKey)
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
        // Restore every project's snapshot — including layout-file projects.
        // The snapshot carries each pane's persisted zmx session identity, so
        // panes REATTACH their still-running shells; force-applying the
        // committed `.macterm/layout.yaml` here would silently destroy them
        // on every launch. The layout now only seeds a genuine first open
        // (no snapshot) — `autoApplyLayoutOnFirstOpen` guards on
        // `workspaces[id] == nil`, so a restored snapshot disables it.
        for ws in WorkspaceSerializer.restore(from: snapshots, validIDs: valid) {
            workspaces[ws.projectID] = ws
        }
        if let id = Preferences.shared.activeProjectID,
           let project = projects.first(where: { $0.id == id })
        {
            activeProjectID = id
            recordProjectVisit(id)
            autoApplyLayoutOnFirstOpen(project)
            ensureWorkspace(projectID: id, path: project.path)
            // Reattaching remote panes need the zmx path before warm/render.
            stampRemoteZmxPath(project)
            acknowledgeActiveTab(projectID: id)
            warmFocusedProject()
        }
        // Sweep crash/force-quit orphans: kill zero-client macterm-* sessions
        // no restored pane claims. Attach-aware and fail-closed (a failed
        // probe reaps nothing); foreign prefixes (supa-*, user sessions) are
        // spared. Quick-terminal sessions are never persisted, so leftovers
        // from a crash die here too.
        let known = Set(workspaces.values
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
            .map(\.sessionName))
        Task { [zmx] in await zmx.reapOrphans(knownSessionNames: known) }
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
        // Stamp the remote zmx path onto every pane BEFORE any surface spawns
        // (warmFocusedProject / render → ensureNSView reads it). It's a host
        // property re-derived from the project on each open, not persisted.
        stampRemoteZmxPath(project)
        acknowledgeActiveTab(projectID: project.id)
        warmFocusedProject()
        // Creating a workspace doesn't change any tab selection (the poll's
        // usual wake signal), so bump it directly.
        notePollEvent()
    }

    /// Apply `project.zmxPath` to every pane in its workspace, so the remote
    /// spawn/kill/probe commands use it. Idempotent; safe to call on each
    /// open. No-op for local projects (nil path leaves PATH resolution).
    private func stampRemoteZmxPath(_ project: Project) {
        guard let ws = workspaces[project.id] else { return }
        for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
            pane.remoteZmxPath = project.zmxPath
        }
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
        // Stagger the spawns: each warm is a login shell (PAM, rc files) and —
        // when restoring — a `zmx attach` reattaching a daemon. Firing them all
        // in one tick multiplies launch pressure with tab count (cmux hit a
        // relaunch memory/PAM storm doing exactly this). 125ms apart keeps
        // relaunch smooth; `warm` is idempotent, so a pane the user views
        // before its slot just spawns early via SwiftUI and the delayed warm
        // no-ops.
        for (index, pane) in Self.panesToWarm(in: ws).enumerated() {
            if index == 0 {
                SurfaceIncubator.shared.warm(pane)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.125 * Double(index)) { [weak pane] in
                guard let pane else { return }
                SurfaceIncubator.shared.warm(pane)
            }
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
    /// build its workspace from the central project file matching its path.
    /// Because there are no live panes, the apply is pure-spawn — never
    /// destructive, never prompts. A restored snapshot already populates
    /// `workspaces`, so it takes precedence; with no applicable file this
    /// no-ops and `ensureWorkspace` creates the default single-pane workspace.
    private func autoApplyLayoutOnFirstOpen(_ project: Project) {
        guard workspaces[project.id] == nil else { return }
        switch projectFiles.applyState(forProjectPath: project.path, preferredSlug: ProjectSlug.slug(from: project.name)) {
        case .applicable:
            applyLayoutPresentingError(project)
        case .invalid:
            // Surface the parse error; the default workspace is created after.
            applyLayoutPresentingError(project)
        case .emptyTabs:
            break
        case .none:
            // Legacy seed: `applyLayoutPresentingError` imports a committed
            // `.macterm/layout.yaml` before applying.
            guard LayoutFile.exists(atProjectRoot: project.path) else { break }
            applyLayoutPresentingError(project)
        }
    }

    /// Deprecated seed path — remove next release (#114): a parseable in-repo
    /// `.macterm/layout.yaml` is imported into the central directory, to then
    /// be applied from there. Throws when the legacy file doesn't parse — the
    /// caller surfaces it; nothing is imported.
    private func importLegacyLayout(_ project: Project) throws {
        let legacy = try LayoutFile.load(fromProjectRoot: project.path)
        try projectFiles.write(
            ProjectFile(name: project.name, path: project.path, tabs: legacy.tabs),
            projectName: project.name
        )
        logger.info("Imported legacy layout for \(project.name, privacy: .public)")
    }

    /// Shows an open panel, adds or finds the selected directory as a project,
    /// and selects it. Returns the selected project, nil if cancelled.
    @discardableResult
    func openProject(store: ProjectStore) -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Always create: picking a folder that already backs a project makes a
        // second, independent project for it, not a jump to the existing one.
        let project = store.create(
            name: url.lastPathComponent,
            path: url.path(percentEncoded: false)
        )
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
              let project = projectStore.projects.first(where: { $0.id == projectID }),
              // Remote projects (#104): the reported pwd is a REMOTE
              // directory — adopting it would corrupt the project's identity.
              !project.isRemote,
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
            // Unload KILLS: with quit now a detach, this is the one action
            // that stops a whole project's shells while keeping its layout
            // (the group-kill #113 asked for). A detaching unload would be
            // a trap — "unloaded" shells silently running forever. The
            // snapshot keeps the layout; reopening spawns fresh shells in
            // the saved cwds (`zmx attach` upserts over the dead names).
            pane.killPersistentSession(using: zmx)
            pane.destroySurface()
        }
        if let restored = WorkspaceSerializer.restore(from: snapshot, validIDs: [projectID]).first {
            workspaces[projectID] = restored
        }
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    /// The teardown half of `removeProject`, without the workspace save — so
    /// a bulk removal can persist once for the whole batch instead of
    /// re-serializing the snapshot per item.
    private func removeProjectWithoutSaving(_ projectID: UUID) {
        logger.debug("removeProject: \(projectID, privacy: .public)")
        if let ws = workspaces[projectID] {
            for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
                // Project removed for good → its sessions die with it.
                pane.killPersistentSession(using: zmx)
                pane.destroySurface()
            }
        }
        workspaces.removeValue(forKey: projectID)
        if activeProjectID == projectID { activeProjectID = nil }
    }

    func removeProject(_ projectID: UUID) {
        removeProjectWithoutSaving(projectID)
        saveWorkspaces()
    }

    /// Remove several projects' workspaces at once — the bulk sidebar delete.
    /// The caller is responsible for pruning the matching `ProjectStore`
    /// entries (that store lives outside AppState). Saves once for the batch.
    func removeProjects(_ projectIDs: [UUID]) {
        guard !projectIDs.isEmpty else { return }
        for id in projectIDs {
            removeProjectWithoutSaving(id)
        }
        saveWorkspaces()
    }

    /// An unload staged for confirmation because one of the project's panes
    /// has a running foreground program — unload now stops every shell in
    /// the project (keeping the layout), so it's destructive.
    struct PendingUnloadProject: Equatable {
        let projectID: UUID
    }

    var pendingUnloadProject: PendingUnloadProject?

    /// Unload a project, confirming first when any pane is busy.
    func requestUnloadProject(_ projectID: UUID) {
        let busy = workspaces[projectID]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .contains { $0.nsView?.needsConfirmQuit() == true } ?? false
        if busy {
            pendingUnloadProject = PendingUnloadProject(projectID: projectID)
            return
        }
        unloadProject(projectID)
    }

    func confirmPendingUnloadProject() {
        guard let pending = pendingUnloadProject else { return }
        pendingUnloadProject = nil
        unloadProject(pending.projectID)
    }

    func cancelPendingUnloadProject() {
        pendingUnloadProject = nil
    }

    /// Run `removal` (the caller's full remove: workspace + project store)
    /// immediately when no pane in the project is busy; otherwise stage it
    /// for the confirmation alert — removal kills every pane's zmx session.
    func requestRemoveProject(_ projectID: UUID, removal: @escaping () -> Void) {
        let busy = workspaces[projectID]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .contains { $0.nsView?.needsConfirmQuit() == true } ?? false
        if busy {
            pendingRemoveProject = PendingRemoveProject(projectID: projectID, completeRemoval: removal)
            return
        }
        removal()
    }

    func confirmPendingRemoveProject() {
        guard let pending = pendingRemoveProject else { return }
        pendingRemoveProject = nil
        pending.completeRemoval()
    }

    func cancelPendingRemoveProject() {
        pendingRemoveProject = nil
    }

    /// A bulk sidebar delete (multi-selection) staged for confirmation because
    /// one or more affected panes has a running foreground program. Holds the
    /// caller's full removal so it can run on confirm — a single dialog for the
    /// whole selection instead of one per item.
    struct PendingBulkRemove {
        let completeRemoval: () -> Void
    }

    var pendingBulkRemove: PendingBulkRemove?

    /// Run `removal` (the caller's full bulk close/remove) immediately when no
    /// affected pane is busy; otherwise stage it behind one confirmation alert.
    /// Mirrors `requestRemoveProject`/`requestCloseTab`, but for a whole
    /// multi-selection so the user confirms once rather than per item.
    func requestRemoveSelection(
        projectIDs: [UUID],
        tabs: [(tabID: UUID, projectID: UUID)],
        removal: @escaping () -> Void
    ) {
        if selectionHasBusyPane(projectIDs: projectIDs, tabs: tabs) {
            pendingBulkRemove = PendingBulkRemove(completeRemoval: removal)
            return
        }
        removal()
    }

    func confirmPendingBulkRemove() {
        guard let pending = pendingBulkRemove else { return }
        pendingBulkRemove = nil
        pending.completeRemoval()
    }

    func cancelPendingBulkRemove() {
        pendingBulkRemove = nil
    }

    /// True when any pane in the given projects (removed whole) or tabs has a
    /// running foreground program needing quit-confirmation.
    private func selectionHasBusyPane(projectIDs: [UUID], tabs: [(tabID: UUID, projectID: UUID)]) -> Bool {
        for id in projectIDs {
            let busy = workspaces[id]?.tabs
                .flatMap { $0.splitRoot.allPanes() }
                .contains { $0.nsView?.needsConfirmQuit() == true } ?? false
            if busy { return true }
        }
        for tab in tabs {
            let busy = workspaces[tab.projectID]?.tabs
                .first { $0.id == tab.tabID }?
                .splitRoot.allPanes()
                .contains { $0.nsView?.needsConfirmQuit() == true } ?? false
            if busy { return true }
        }
        return false
    }

    // MARK: - Tabs

    /// A `command` spawns in the new tab's pane via `initial_input` (layout
    /// `run:` semantics). Returns the new tab's ID, nil when the project has
    /// no live workspace.
    @discardableResult
    func createTab(projectID: UUID, projectPath: String, command: String? = nil) -> UUID? {
        guard let ws = workspaces[projectID] else { return nil }
        let tab = ws.createTab(projectPath: projectPath, command: command)
        logger.debug("createTab: project=\(projectID, privacy: .public) tabs=\(ws.tabs.count, privacy: .public)")
        saveWorkspaces()
        return tab.id
    }

    /// Convenience overload: look up the project's canonical path from the
    /// given projects list so new tabs always land in the project directory,
    /// not whatever cwd the last pane drifted to.
    func createTab(projectID: UUID, projects: [Project]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        createTab(projectID: projectID, projectPath: project.path)
    }

    /// The teardown half of `closeTab`, without the workspace save — so a
    /// bulk close can persist once for the whole batch.
    private func closeTabWithoutSaving(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.debug("closeTab: \(tabID, privacy: .public) project=\(projectID, privacy: .public)")
        for pane in tab.splitRoot.allPanes() {
            // Tab closed for good → its panes' zmx sessions die with it.
            pane.killPersistentSession(using: zmx)
            pane.destroySurface()
        }
        ws.closeTab(tabID)
    }

    func closeTab(_ tabID: UUID, projectID: UUID) {
        closeTabWithoutSaving(tabID, projectID: projectID)
        saveWorkspaces()
    }

    /// Close several tabs at once — the bulk sidebar delete for tabs. Each is
    /// identified by its owning project since a multi-selection can span
    /// projects. Saves once for the batch.
    func closeTabs(_ tabs: [(tabID: UUID, projectID: UUID)]) {
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            closeTabWithoutSaving(tab.tabID, projectID: tab.projectID)
        }
        saveWorkspaces()
    }

    /// Close a tab, confirming first when any of its panes has a running
    /// foreground program — closing kills the panes' zmx sessions, so the
    /// destructive-confirmation lives here (quit will detach, not kill).
    func requestCloseTab(_ tabID: UUID, projectID: UUID) {
        let tab = workspaces[projectID]?.tabs.first { $0.id == tabID }
        let busy = tab?.splitRoot.allPanes()
            .contains { $0.nsView?.needsConfirmQuit() == true } ?? false
        if busy {
            pendingCloseTab = PendingCloseTab(tabID: tabID, projectID: projectID)
            return
        }
        closeTab(tabID, projectID: projectID)
    }

    func confirmPendingCloseTab() {
        guard let pending = pendingCloseTab else { return }
        pendingCloseTab = nil
        closeTab(pending.tabID, projectID: pending.projectID)
    }

    func cancelPendingCloseTab() {
        pendingCloseTab = nil
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
    /// selected, so the user lands where they meant to be. `toIndex` positions
    /// the tab within the destination (a sidebar drop lands at a slot); nil
    /// appends. No-op for a same-project move or an unknown source/tab.
    func moveTab(
        _ tabID: UUID,
        from sourceProjectID: UUID,
        to destProjectID: UUID,
        destPath: String,
        toIndex: Int? = nil
    ) {
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
        dest.adoptTab(tab, at: toIndex)
        // Restamp the moved panes' routing identity to the destination project.
        // Without this they keep the SOURCE projectID, so a later
        // notification-click navigates to the old project and can't find the
        // tab. Only the routing key changes — session identity (name/host)
        // stays put, so a moved remote pane still tears down over ssh.
        for pane in tab.splitRoot.allPanes() {
            pane.rebind(projectID: destProjectID)
        }
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Reorder a tab within its own project to an absolute drop index (the
    /// offset a sidebar drag-and-drop reports). Persists on a real move.
    func reorderTab(_ tabID: UUID, inProject projectID: UUID, toIndex destination: Int) {
        guard let ws = workspaces[projectID] else { return }
        let before = ws.tabs.map(\.id)
        ws.moveTab(tabID, toIndex: destination)
        if ws.tabs.map(\.id) != before { saveWorkspaces() }
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

    /// Split a SPECIFIC pane — found in whichever of the project's tabs holds
    /// it, unlike the focused-pane overload above — optionally spawning
    /// `command` in the new pane. The control CLI's split path. Returns the
    /// new pane's ID.
    @discardableResult
    func splitPane(
        _ paneID: UUID,
        direction: SplitDirection,
        projectID: UUID,
        command: String? = nil
    ) -> UUID? {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil })
        else { return nil }
        let newID = tab.split(paneID: paneID, direction: direction, command: command)
        saveWorkspaces()
        return newID
    }

    /// Split a pane into an equal `rows`×`columns` grid (see
    /// `TerminalTab.makeGrid`), spawning `command` in each new pane. Returns
    /// the new pane IDs.
    @discardableResult
    func makeGrid(
        _ paneID: UUID,
        rows: Int,
        columns: Int,
        projectID: UUID,
        command: String? = nil
    ) -> [UUID] {
        guard let ws = workspaces[projectID],
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil })
        else { return [] }
        let created = tab.makeGrid(paneID: paneID, rows: rows, columns: columns, command: command)
        if !created.isEmpty { saveWorkspaces() }
        return created
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
        // Pane closed for good → its zmx session dies with it. (The
        // onlyPaneLeft path below re-kills via closeTab; killSession is a
        // no-op on a missing session, so the overlap is harmless.)
        tab.splitRoot.findPane(id: paneID)?.killPersistentSession(using: zmx)
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

    /// Apply the central project file matching `project.path` to its live
    /// workspace, reconciling with minimal destruction (see
    /// `LayoutReconciler`). A non-destructive reconcile (only spawns +
    /// resizes) runs immediately; one that would terminate panes/tabs is
    /// staged in `pendingLayoutApply` for confirmation. Returns an error to
    /// surface when no file matches, the file is unparseable, or it declares
    /// no tabs (an empty declaration must never plan "close every tab").
    @discardableResult
    func applyLayout(project: Project) -> Error? {
        logger.info("applyLayout: project=\(project.name, privacy: .public)")
        let layout: LayoutFile
        do {
            guard let file = try projectFiles.loadFull(
                forProjectPath: project.path,
                preferredSlug: ProjectSlug.slug(from: project.name)
            ) else {
                return LayoutFileError.noProjectFile(projectPath: project.path)
            }
            guard let bridged = file.layoutFile else {
                return LayoutFileError.noTabs
            }
            layout = bridged
        } catch {
            logger.error("applyLayout failed to load: \(error, privacy: .public)")
            return error
        }
        let plan = LayoutReconciler.plan(
            layout: layout,
            workspace: workspaces[project.id],
            projectRoot: project.path,
            projectID: project.id
        )
        let planDesc = "tabs=\(plan.tabs.count) destroy=\(plan.panesToDestroy.count) closeTabs=\(plan.tabsToClose.count)"
        logger.info("applyLayout plan: \(planDesc, privacy: .public)")
        if plan.isDestructive {
            logger.info("applyLayout: staged for confirmation")
            pendingLayoutApply = PendingLayoutApply(projectID: project.id, plan: plan)
        } else {
            executeLayoutPlan(plan, projectID: project.id)
        }
        return nil
    }

    /// `applyLayout` + error presentation: failures land in
    /// `pendingLayoutError` (the alert in `MactermApp`). The shared entry
    /// point for the palette/menu command and the first-open auto-apply.
    ///
    /// When no central file declares the project's path but a committed
    /// legacy `.macterm/layout.yaml` exists, it's imported first (deprecated
    /// seed, #114). Explicit apply needs this as much as first open does:
    /// an existing project always has a restored snapshot, so first-open
    /// never fires for it — without this, its legacy file would be
    /// unreachable for the whole deprecation window.
    func applyLayoutPresentingError(_ project: Project) {
        if projectFiles.find(forProjectPath: project.path, preferredSlug: ProjectSlug.slug(from: project.name)) == nil,
           LayoutFile.exists(atProjectRoot: project.path)
        {
            do {
                try importLegacyLayout(project)
            } catch {
                logger.error("Legacy layout import failed: \(error, privacy: .public)")
                pendingLayoutError = LayoutError(verb: "import", message: error.localizedDescription)
                return
            }
        }
        if let error = applyLayout(project: project) {
            pendingLayoutError = LayoutError(verb: "apply", message: error.localizedDescription)
        }
    }

    func confirmPendingLayoutApply() {
        guard let pending = pendingLayoutApply else { return }
        pendingLayoutApply = nil
        executeLayoutPlan(pending.plan, projectID: pending.projectID)
    }

    func cancelPendingLayoutApply() {
        pendingLayoutApply = nil
    }

    /// Save the project's live workspace as its central project file — one of
    /// the two ways a project file ever changes (the other is the user's own
    /// editor). Creates the file when none declares this path yet; realigns
    /// the filename to the current name slug when it drifted.
    /// `siblingProjects` is the full project list, used only to detect another
    /// project that shares this directory and filename slug (and would thus
    /// share the same layout file). AppState doesn't own the `ProjectStore`, so
    /// callers pass it; the default empty list keeps the shared-path check
    /// inert for callers that don't have it (and for tests that don't care).
    @discardableResult
    func saveLayout(project: Project, siblingProjects: [Project] = []) -> Error? {
        logger.info("saveLayout: project=\(project.name, privacy: .public)")
        guard let ws = workspaces[project.id] else { return nil }
        // Reserve the *other* same-directory projects' files so the save leaves
        // them alone. Drop our own slug: a same-*name* sibling shares our slug
        // and thus our file (last save wins — flagged below), so it must not
        // reserve that file away from us.
        let ownSlug = ProjectSlug.slug(from: project.name)
        let reservedSlugs = sameDirectorySiblingSlugs(of: project, in: siblingProjects).subtracting([ownSlug])
        do {
            let layout = LayoutSerializer.layout(for: ws, projectName: project.name, projectRoot: project.path)
            let target = try projectFiles.write(
                ProjectFile(name: project.name, path: project.path, zmxPath: project.zmxPath, tabs: layout.tabs),
                projectName: project.name,
                reservedSlugs: reservedSlugs
            )
            logger.info("saveLayout succeeded: tabs=\(ws.tabs.count, privacy: .public)")
            // A stray-*file* conflict (an unrelated file declares this path)
            // takes priority over the shared-*project* notice — both write
            // `pendingLayoutError`, so only surface the latter when the former
            // stayed quiet.
            if !presentSaveConflictIfNeeded(project: project, savedTo: target, siblingProjects: siblingProjects) {
                presentSharedPathConflictIfNeeded(project: project, savedTo: target, siblingProjects: siblingProjects)
            }
            return nil
        } catch {
            logger.error("saveLayout failed: \(error, privacy: .public)")
            return error
        }
    }

    /// Slugs of the *other* projects that back `project`'s directory — the
    /// layout files that are theirs, not this project's. Lets a save leave a
    /// sibling's file alone, and tells a sibling's legitimate file apart from a
    /// stray duplicate.
    private func sameDirectorySiblingSlugs(of project: Project, in siblingProjects: [Project]) -> Set<String> {
        Set(
            siblingProjects
                .filter { $0.id != project.id && ProjectPath.matches($0.path, project.path) }
                .map { ProjectSlug.slug(from: $0.name) }
        )
    }

    /// A save that lands next to *stray* files declaring the same path — ones
    /// that are neither this project's own file nor a sibling project's — gets
    /// a visible notice. The slug-preferring lookup ignores such strays (a
    /// hand-authored copy, or an old file whose realign-delete failed), so warn
    /// they exist rather than let them rot silently.
    @discardableResult
    private func presentSaveConflictIfNeeded(project: Project, savedTo target: URL, siblingProjects: [Project]) -> Bool {
        let siblingSlugs = sameDirectorySiblingSlugs(of: project, in: siblingProjects)
        let strays = projectFiles.matches(forProjectPath: project.path).filter { file in
            let name = file.url.lastPathComponent
            // The file we just wrote is not in conflict with itself, and a
            // sibling project's own file is expected, not a stray.
            guard name != target.lastPathComponent else { return false }
            return !siblingSlugs.contains { ProjectSlug.owns(filename: name, slug: $0) }
        }
        guard !strays.isEmpty else { return false }
        let names = strays.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
        pendingLayoutError = LayoutError(
            verb: "save",
            message: "The layout was saved to “\(target.lastPathComponent)”, but these other files also "
                + "declare this project’s path and are ignored: \(names). "
                + "Remove or merge them in the projects directory.",
            customTitle: "Layout saved with a conflict"
        )
        return true
    }

    /// A directory can back several projects, and a project's layout file is
    /// keyed by path **and** name-slug — so a same-path project whose name
    /// yields the *same* slug writes to the very file this save just wrote, and
    /// the last save silently wins. Flag exactly that pair: same canonical path
    /// AND same slug. Same path but distinct names is fine — those resolve to
    /// distinct slug files (`api.yaml` / `api-staging.yaml`) that load
    /// independently and never overwrite each other.
    private func presentSharedPathConflictIfNeeded(project: Project, savedTo target: URL, siblingProjects: [Project]) {
        let slug = ProjectSlug.slug(from: project.name)
        let colliding = siblingProjects.filter {
            $0.id != project.id
                && ProjectPath.matches($0.path, project.path)
                && ProjectSlug.slug(from: $0.name) == slug
        }
        guard !colliding.isEmpty else { return }
        let names = colliding.map { "“\($0.name)”" }.joined(separator: ", ")
        pendingLayoutError = LayoutError(
            verb: "save",
            message: "\(names) share this directory and layout file "
                + "“\(target.lastPathComponent)” with this project. Saving here overwrote their "
                + "layout, and each save wins over the last. Give the projects distinct names to "
                + "keep separate layout files.",
            customTitle: "Layout file shared with another project"
        )
    }

    /// `saveLayout` + error presentation, mirroring `applyLayoutPresentingError`.
    func saveLayoutPresentingError(_ project: Project, siblingProjects: [Project] = []) {
        if let error = saveLayout(project: project, siblingProjects: siblingProjects) {
            pendingLayoutError = LayoutError(verb: "save", message: error.localizedDescription)
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
        // A layout-dropped pane is gone for good (no declared node claims it),
        // so its zmx session dies too — otherwise it would linger as a
        // clients==0 daemon.
        for pane in plan.panesToDestroy {
            pane.killPersistentSession(using: zmx)
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
            // Resolve the target window INSIDE the deferred continuation:
            // `NSApp.activate()` is asynchronous, so reading keyWindow/mainWindow
            // synchronously here (the common caller is a notification click while
            // Macterm is inactive) returns nil and makes restoreFocus no-op. Fall
            // back to the AppDelegate's cached terminal window when both are still
            // nil (an ordered-out/unfocused SwiftUI window reports neither).
            DispatchQueue.main.async {
                let window = NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? (NSApp.delegate as? AppDelegate)?.mainWindow
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
        // Route through the injected `isAppActive` seam (not `NSApp.isActive`
        // directly): NSApp is nil during construction and unset in tests, and
        // this path is reachable from init via pollNow().
        guard isAppActive(),
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
