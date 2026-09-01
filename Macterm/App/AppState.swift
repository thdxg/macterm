import AppKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState")

/// Thread-safe ownership for block-based notification observers. `AppState`
/// installs observers on the main actor, while Swift deinitializers are
/// nonisolated; keeping the non-Sendable tokens behind this lock lets teardown
/// drain them without unsafe actor annotations on observable state.
private final class ObserverTokenStore: @unchecked Sendable {
    private typealias Entry = (center: NotificationCenter, token: NSObjectProtocol)

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(center: NotificationCenter, token: NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((center, token))
    }

    func append(contentsOf newEntries: [(center: NotificationCenter, token: NSObjectProtocol)]) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(contentsOf: newEntries)
    }

    func removeAllObservers() {
        lock.lock()
        let drained = entries
        entries.removeAll()
        lock.unlock()

        for entry in drained {
            entry.center.removeObserver(entry.token)
        }
    }
}

@MainActor @Observable
final class AppState {
    var activeProjectID: UUID? {
        didSet {
            Preferences.shared.activeProjectID = activeProjectID
            // Becoming active IS the reload — `warmFocusedProject` only ever
            // spawns the focused project's shells — so this is the one choke
            // point every load path passes through, whether it went via
            // `selectProject` or set the id directly (a cross-project tab
            // move, a merge, a global tab cycle).
            if let activeProjectID { unloadedProjectIDs.remove(activeProjectID) }
        }
    }

    var workspaces: [UUID: Workspace] = [:]

    /// Projects the user unloaded this session: their shells were killed and
    /// only the layout kept. The sidebar dims their tab rows the way an
    /// unloaded pinned record's row is dimmed — same meaning, "not running,
    /// select to bring it back". Deliberately in-memory: after a relaunch
    /// every project is lazy again, so a persisted mark would dim rows whose
    /// sessions are merely detached rather than dead.
    private(set) var unloadedProjectIDs: Set<UUID> = []

    /// Ordered pinned-tab records — the sidebar's pinned section. A record
    /// whose id matches a live tab in the pinned workspace
    /// (`workspaces[PinnedTabs.projectID]`) is loaded; the rest are unloaded
    /// (their sessions died) and rebuild from their declaration on selection.
    /// All mutation goes through `AppState+PinnedTabs.swift`.
    var pinnedRecords: [PinnedTabRecord] = []

    /// `pinned.yaml` I/O. Shares the project-file directory, so a test's
    /// injected `ProjectFileStore` tempdir isolates this file too.
    @ObservationIgnored
    var pinnedLayoutStore: PinnedLayoutStore

    /// The exact text of our own last `pinned.yaml` write — the baseline that
    /// detects external edits at the next write (see
    /// `writePinnedLayout`). nil = never written this run.
    @ObservationIgnored
    var pinnedLayoutLastWrittenText: String?

    /// Membership (record ids, in order) as of the last `pinned.yaml` write,
    /// so `saveWorkspaces` only rewrites the file when the pinned SET changed
    /// — not on every workspace save. nil = no baseline yet, which also stops
    /// a pre-restore save from clobbering the user's file with an empty list.
    @ObservationIgnored
    var pinnedMembershipStamp: [UUID]?

    /// Auto-writes to `pinned.yaml` are paused because the on-disk file is
    /// unparseable (or lost its `path: <pinned>` marker) — overwriting would
    /// destroy the user's mid-edit work. Cleared when a later read parses.
    var pinnedLayoutSuspended = false

    /// Live tab snapshots restored from the workspace file but not yet
    /// materialized: `materializeRestoredPinnedTabs()` first asks zmx which
    /// sessions actually survived, so a dead pinned tab restores from its
    /// declaration (re-running its `run:`) instead of upserting a bare shell.
    @ObservationIgnored
    var pendingPinnedLiveRestores: [UUID: TabSnapshot] = [:]

    /// The pinned tab that was selected at last quit, applied once by
    /// `materializeRestoredPinnedTabs` (the sentinel workspace is excluded
    /// from the ordinary snapshots, which is where every other workspace
    /// keeps its selection).
    @ObservationIgnored
    var pendingPinnedActiveTabID: UUID?

    /// Each pinned pane's last-seen foreground name, so the poll can tell
    /// when a pinned tab started or stopped a process — the trigger that
    /// re-captures its declaration (and rewrites `pinned.yaml`, debounced)
    /// so the respawn recipe tracks what's actually running, not just what
    /// ran at pin time.
    @ObservationIgnored
    var pinnedForegroundStamp: [UUID: String?] = [:]

    /// The debounced declaration-refresh write (see
    /// `notePinnedForegroundChangesIfNeeded`).
    @ObservationIgnored
    var pinnedDeclarationPersistWork: DispatchWorkItem?

    /// Starts a background pane's shell off-screen (the incubator). A seam so
    /// unit tests of the eager pinned-tab launch never create real ghostty
    /// surfaces (and thus never spawn shells) inside the test host.
    @ObservationIgnored
    var warmPane: (Pane) -> Void = { SurfaceIncubator.shared.warm($0) }
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

    /// Which window presents a dialog `AppState` stages.
    ///
    /// Both scenes in `MactermApp` — the main `WindowGroup` and `Settings` —
    /// attach alerts to the *same* pending state, because Settings → Projects
    /// drives the same destructive project/layout mutations and the settings
    /// window needs its own copy of each confirmation. With no gate, one
    /// request presents twice: SwiftUI materializes and fronts the settings
    /// window purely to show its duplicate, stacking an identical dialog on
    /// top of the one the user is looking at. So every staged dialog records
    /// the scene that asked for it, and each scene's `isPresented` binding
    /// reads only its own. The default is the main window; only the settings
    /// pane's call sites pass `.settings`.
    enum DialogHost: Equatable {
        case mainWindow
        case settings
    }

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
        var host: DialogHost = .mainWindow
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
        var host: DialogHost = .mainWindow

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
        var host: DialogHost = .mainWindow
        var title: String { customTitle ?? "Couldn't \(verb) layout" }
    }

    var pendingLayoutError: LayoutError?

    /// Bumped whenever the app itself writes a project file, so an open
    /// Projects settings pane can re-read the directory. There's no file
    /// watcher by design (hand-edits surface on next use); this covers only
    /// the changes Macterm makes, which the user does expect to see land.
    private(set) var layoutFilesVersion = 0

    func noteLayoutFilesChanged() {
        layoutFilesVersion &+= 1
    }

    /// The transient success confirmation showing in `ToastOverlay`, if any.
    /// Only for outcomes that leave no visible trace — failures still raise a
    /// dialog, which a toast must never replace.
    private(set) var activeToast: Toast?

    /// Show `toast`, replacing any toast already up (the newest outcome is the
    /// one worth reading).
    func presentToast(_ title: String, subtitle: String? = nil) {
        activeToast = Toast(title: title, subtitle: subtitle)
    }

    /// Dismiss the toast with `id` — a no-op if it was already replaced by a
    /// newer one, so a stale auto-dismiss can't cut the new toast short.
    func dismissToast(_ id: UUID) {
        guard activeToast?.id == id else { return }
        activeToast = nil
    }

    /// Presents the "New Remote Project" sheet (#104) — set by the palette
    /// command and the sidebar's New Project menu, consumed by `MainWindow`.
    var isNewRemoteProjectSheetPresented = false

    // Tab cycling state (Ctrl+Tab)
    private var tabCycleOrder: [UUID] = []
    private var tabCycleIndex: Int = 0
    var isTabCycling: Bool { !tabCycleOrder.isEmpty }

    private let workspaceStore: WorkspaceStore
    /// Per-pane attempt gating for the reconnect sweep (#281). Not observed —
    /// pure bookkeeping, no UI reads it.
    @ObservationIgnored
    private var reconnectPolicy = RemoteReconnectPolicy()
    /// Orphan-sweep throttle (#281): destination (`user@host`, or
    /// `localSweepKey` for the local daemon) → when it was last swept.
    @ObservationIgnored
    private var sweptDestinations: [String: Date] = [:]
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
    /// so `deinit` can remove them from the correct center.
    private let observerTokens = ObserverTokenStore()

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
        pinnedLayoutStore = PinnedLayoutStore(directoryURL: projectFiles.directoryURL)
        let autoTileToken = NotificationCenter.default.addObserver(
            forName: .autoTilingEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebalanceAllWorkspacesIfEnabled() }
        }
        autoTileObserver = autoTileToken
        observerTokens.append(center: NotificationCenter.default, token: autoTileToken)
        let restored = (Preferences.defaults.stringArray(forKey: recencyKey) ?? [])
            .compactMap { UUID(uuidString: $0) }
        projectRecency = RecencyStack<UUID>(limit: 50, items: restored)

        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let onEvent: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.notePollEvent() }
        }
        let onQuietSettleDeadline: @Sendable (Notification) -> Void = { [weak self] _ in
            // Do not route through notePollEvent: if another poll ran within
            // 250ms, coalescing plus a fully occluded window would pause with
            // no timer and never retry this deadline.
            MainActor.assumeIsolated { self?.pollNow() }
        }
        let tokens: [(NotificationCenter, NSObjectProtocol)] = [
            (center, center.addObserver(forName: .terminalPollEvent, object: nil, queue: .main, using: onEvent)),
            (center, center.addObserver(
                forName: .terminalQuietSettleDeadline,
                object: nil,
                queue: .main,
                using: onQuietSettleDeadline
            )),
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
        // The poll timer self-cleans: it's non-repeating with a `[weak self]`
        // closure, so a dead instance's timer fires once into nil and stops.
        observerTokens.removeAllObservers()
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
        var sawBusyPane = false
        var activeRemotePanes: [Pane] = []
        for (projectID, ws) in workspaces {
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() {
                    if pane.isRemote {
                        // The local process table only knows `ssh` here — a
                        // local refresh would stomp the probe-derived name
                        // and instantly expire remote OSC titles. Execution
                        // state still settles from output heartbeats, and
                        // the frontmost project's panes feed the throttled
                        // remote probe below. A pane holding a boundary
                        // request rides along from ANY project — a command
                        // finishing in a background project must still
                        // rename its tab without waiting for a switch.
                        if projectID == activeProjectID || pane.remoteProbePending {
                            activeRemotePanes.append(pane)
                        }
                    } else {
                        pane.refreshForegroundProcess(trackExecution: trackExecution)
                    }
                    // An activity-sourced run whose output has been quiet past
                    // the window settles to `.done`. The output heartbeat is
                    // occlusion-independent, so silence is meaningful whether or
                    // not the pane is on screen — no occlusion special-casing.
                    if trackExecution {
                        pane.settleTerminalActivityIfQuiet()
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
        lastPollSawBusyPane = sawBusyPane
        if didAcknowledgeCompletion { saveWorkspaces() }
        // A pinned pane's foreground changing (a command started or ended) is
        // the cue to re-capture its tab's declaration, so the respawn recipe
        // tracks what the tab is actually doing — not just what it did at pin
        // time. Cheap in steady state: a name compare per pinned pane.
        notePinnedForegroundChangesIfNeeded()
        // Visibility gates only the *scheduled* probes (nobody is looking at
        // the names). A boundary request still probes while occluded — same
        // rationale as the local #210 refresh, which runs unconditionally —
        // so the name is already right when the window next appears instead
        // of waiting for an interaction.
        let panesToProbe = isAnyWindowVisible()
            ? activeRemotePanes
            : activeRemotePanes.filter(\.remoteProbePending)
        // The background-connections toggle gates ALL probe kinds — scheduled,
        // boundary, and priming requests alike — because each is a fresh ssh
        // connection, and one connection is one Touch ID dialog on a
        // biometric-gated key (#272). This is the single resolver call site,
        // so the check lives here rather than inside the resolver.
        if !panesToProbe.isEmpty, Preferences.shared.backgroundSSHConnections {
            remoteForegroundResolver.refresh(panes: panesToProbe, probe: zmx.remoteForegrounds)
        }
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
        let loaded = workspaceStore.load()
        let valid = Set(projects.map(\.id))
        // Restore every project's snapshot — including layout-file projects.
        // The snapshot carries each pane's persisted zmx session identity, so
        // panes REATTACH their still-running shells; force-applying the
        // project file's declared layout here would silently destroy them
        // on every launch. The layout now only seeds a genuine first open
        // (no snapshot) — `autoApplyLayoutOnFirstOpen` guards on
        // `workspaces[id] == nil`, so a restored snapshot disables it.
        for ws in WorkspaceSerializer.restore(from: loaded.workspaces, validIDs: valid) {
            workspaces[ws.projectID] = ws
        }
        // Pinned tabs: records first, then the launch reconcile against
        // `pinned.yaml` (the file is authoritative for membership — see
        // AppState+PinnedTabs). Live tabs materialize async, after zmx says
        // which sessions actually survived.
        restorePinnedState(loaded.pinned, activeTabID: loaded.pinnedActiveTabID)
        reconcilePinnedLayoutAtLaunch(projects: projects)
        if let id = Preferences.shared.activeProjectID {
            if id == PinnedTabs.projectID {
                if !pinnedRecords.isEmpty {
                    ensurePinnedWorkspace()
                    activeProjectID = id
                }
            } else if let project = projects.first(where: { $0.id == id }) {
                activeProjectID = id
                recordProjectVisit(id)
                autoApplyLayoutOnFirstOpen(project)
                ensureWorkspace(projectID: id, path: project.path)
                // Reattaching remote panes need the zmx path before warm/render.
                stampRemoteZmxPath(project)
                acknowledgeActiveTab(projectID: id)
            }
        }
        if Preferences.shared.restoreAllProjectsOnLaunch {
            warmRestoredProjects(projects)
        } else {
            warmFocusedProject()
        }
        // Sweep crash/force-quit orphans: kill zero-client macterm-* sessions
        // no restored pane claims. Attach-aware and fail-closed (a failed
        // probe reaps nothing, and a failed snapshot LOAD sweeps nothing —
        // an empty claim set would mark every live session an orphan);
        // foreign prefixes (supa-*, user sessions) are spared.
        // Quick-terminal sessions are never persisted, so leftovers from a
        // crash die here too.
        // Pinned live tabs materialize async, after zmx says which sessions
        // survived (#285) — ahead of the loadFailed gate, since pinned
        // records come from pinned.yaml, not the snapshot.
        Task { await materializeRestoredPinnedTabs(projects: projects) }
        guard !workspaceStore.loadFailed else { return }
        sweptDestinations[Self.localSweepKey] = Date()
        let known = claimedSessionNames()
        Task { [zmx] in await zmx.reapOrphans(knownSessionNames: known) }
        // The active project's remote host gets the labelled sweep (#281);
        // other hosts are swept when their projects are selected.
        if let id = activeProjectID, let project = projects.first(where: { $0.id == id }) {
            sweepOrphanSessions(project: project)
        }
    }

    func saveWorkspaces() {
        // Any mutation can have created a tab inside the pinned workspace
        // (CLI `tab new`, a pane separated into it, a merge) — make sure it
        // has a record before the snapshot serializes.
        syncPinnedRecordsWithWorkspace()
        let ordinary = workspaces.filter { $0.key != PinnedTabs.projectID }
        workspaceStore.save(
            WorkspaceSerializer.snapshot(ordinary),
            pinned: WorkspaceSerializer.snapshotPinned(
                records: pinnedRecords,
                workspace: workspaces[PinnedTabs.projectID]
            ),
            // The pinned workspace is excluded from `ordinary`, so it loses
            // the WorkspaceSnapshot.activeTabID every other workspace keeps —
            // carry the selection separately or a relaunch always lands on
            // the first pinned row.
            pinnedActiveTabID: workspaces[PinnedTabs.projectID]?.activeTabID
        )
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
        reconnectDroppedRemotePanes(trigger: .projectSelected)
        sweepOrphanSessions(project: project)
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
    /// `SurfaceIncubator`.
    func warmFocusedProject() {
        guard let projectID = activeProjectID, let ws = workspaces[projectID] else { return }
        warmStaggered(Self.panesToWarm(in: ws))
    }

    /// Start every restored ordinary project's shells without changing the
    /// selected project. Background projects need every pane warmed; the
    /// selected project's active tab is already rendered by SwiftUI, so only
    /// its other tabs go through the incubator. All panes share one staggered
    /// batch to avoid multiplying login/SSH pressure at launch.
    func warmRestoredProjects(_ projects: [Project]) {
        for project in projects where workspaces[project.id] != nil {
            // Background remote panes never pass through selectProject, so
            // stamp their configured zmx path before their surfaces spawn.
            stampRemoteZmxPath(project)
        }
        let panes = Self.panesToWarmAtLaunch(
            projectIDs: projects.map(\.id),
            workspaces: workspaces,
            activeProjectID: activeProjectID
        )
        logger.info("warmRestoredProjects: starting \(panes.count, privacy: .public) background pane(s)")
        let visibleRemoteDestinations = Self.visibleRemoteDestinations(
            activeProjectID: activeProjectID,
            workspaces: workspaces
        )
        warmScheduled(Self.launchWarmSchedule(
            panes,
            alreadyStartingRemoteDestinations: visibleRemoteDestinations
        ))
    }

    /// Start panes' shells off-screen, staggered 125ms apart: each warm is a
    /// login shell (PAM, rc files) and — when restoring — a `zmx attach`
    /// reattaching a daemon, and firing them all in one tick multiplies
    /// launch pressure with pane count (cmux hit a relaunch memory/PAM storm
    /// doing exactly this). The warm is idempotent, so a pane the user views
    /// before its slot just spawns early via SwiftUI and the delayed warm
    /// no-ops. `afterEach` runs right after a pane's warm (the pinned
    /// workspace wires its process-exit callback there).
    func warmStaggered(_ panes: [Pane], afterEach: @escaping (Pane) -> Void = { _ in }) {
        warmScheduled(panes.enumerated().map { index, pane in
            LaunchWarmStep(pane: pane, delay: 0.125 * Double(index))
        }, afterEach: afterEach)
    }

    private func warmScheduled(
        _ steps: [LaunchWarmStep],
        afterEach: @escaping (Pane) -> Void = { _ in }
    ) {
        for step in steps {
            if step.delay == 0 {
                warmPane(step.pane)
                afterEach(step.pane)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self, weak pane = step.pane] in
                guard let self, let pane else { return }
                self.warmPane(pane)
                afterEach(pane)
            }
        }
    }

    struct LaunchWarmStep {
        let pane: Pane
        let delay: TimeInterval
    }

    /// Build the eager-launch schedule without making local restoration pay
    /// for remote connection setup. Local panes retain the ordinary 125ms
    /// stagger. Remote panes going to the same ssh destination get one-second
    /// slots so the first connection can establish the user's ControlMaster
    /// before the rest try to multiplex through it. The visible tab is already
    /// rendering outside the incubator, so its destination occupies the first
    /// slot even though none of its panes appear in `panes`.
    static func launchWarmSchedule(
        _ panes: [Pane],
        alreadyStartingRemoteDestinations: Set<String> = []
    ) -> [LaunchWarmStep] {
        var lastRemoteDelay = Dictionary(uniqueKeysWithValues:
            alreadyStartingRemoteDestinations.map { ($0, 0.0) }
        )

        return panes.enumerated().map { index, pane in
            let ordinaryDelay = 0.125 * Double(index)
            guard let destination = remoteDestination(for: pane) else {
                return LaunchWarmStep(pane: pane, delay: ordinaryDelay)
            }

            let delay: TimeInterval = if let previous = lastRemoteDelay[destination] {
                max(ordinaryDelay, previous + 1.0)
            } else {
                ordinaryDelay
            }
            lastRemoteDelay[destination] = delay
            return LaunchWarmStep(pane: pane, delay: delay)
        }
    }

    private static func visibleRemoteDestinations(
        activeProjectID: UUID?,
        workspaces: [UUID: Workspace]
    ) -> Set<String> {
        guard let activeProjectID,
              let workspace = workspaces[activeProjectID],
              let activeTab = workspace.tabs.first(where: { $0.id == workspace.activeTabID })
        else { return [] }
        return Set(activeTab.splitRoot.allPanes().compactMap(remoteDestination(for:)))
    }

    private static func remoteDestination(for pane: Pane) -> String? {
        guard case let .remote(user, host, _)? = pane.remoteSpec else { return nil }
        return RemoteSpawn.destination(user: user, host: host)
    }

    /// Panes whose shells should be eagerly started: every pane in every tab
    /// except the active tab (SwiftUI starts the active tab's panes when it
    /// renders them). Pure, so it's unit-testable without surfaces.
    static func panesToWarm(in workspace: Workspace) -> [Pane] {
        workspace.tabs
            .filter { $0.id != workspace.activeTabID }
            .flatMap { $0.splitRoot.allPanes() }
    }

    /// Panes to start when eager launch restoration is enabled. Project order
    /// is supplied explicitly so the stagger is deterministic and follows the
    /// sidebar. A restored project that is not selected is entirely off-screen
    /// and therefore needs all of its panes warmed.
    static func panesToWarmAtLaunch(
        projectIDs: [UUID],
        workspaces: [UUID: Workspace],
        activeProjectID: UUID?
    ) -> [Pane] {
        projectIDs.flatMap { projectID -> [Pane] in
            guard let workspace = workspaces[projectID] else { return [] }
            if projectID == activeProjectID {
                return panesToWarm(in: workspace)
            }
            return workspace.tabs.flatMap { $0.splitRoot.allPanes() }
        }
    }

    // MARK: - Remote reconnect (#281)

    /// What woke the reconnect sweep. Logging only — the policy treats all
    /// triggers identically (attempts are gated per pane, not per trigger).
    enum ReconnectTrigger: String {
        case wake
        case activate
        case projectSelected
    }

    /// Redial the active project's dropped remote panes: any pane whose ssh
    /// client died (libghostty's abnormal-exit overlay) while its remote zmx
    /// session lives on. Respawning the surface re-runs the same
    /// `ssh -t … exec zmx attach <sessionName>`, and zmx replays scrollback
    /// on re-attach — per pane, exactly what quit-and-relaunch does today.
    ///
    /// Trigger-driven only (system wake / app activation / project
    /// selection), never a timer, and rate-limited per pane by
    /// `RemoteReconnectPolicy`, so a still-unreachable host is retried a
    /// bounded number of times per return — not polled. Active project only,
    /// mirroring the foreground probe's frontmost-only rule; other projects
    /// reconnect via the `.projectSelected` trigger when opened.
    func reconnectDroppedRemotePanes(trigger: ReconnectTrigger) {
        guard Preferences.shared.reconnectRemotePanes else { return }
        // A wake-burst closure can land mid-quit; respawning a surface while
        // the teardown sweep is killing them would resurrect ssh clients.
        guard !AppTerminationState.isTerminating else { return }
        guard let projectID = activeProjectID, let ws = workspaces[projectID] else { return }
        let now = Date()
        var reconnectedIDs: Set<UUID> = []
        for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) where pane.isRemote {
            guard pane.isDisconnected else {
                reconnectPolicy.observeAlive(pane.id, now: now)
                continue
            }
            guard reconnectPolicy.shouldAttempt(pane.id, now: now) else { continue }
            reconnectPolicy.recordAttempt(pane.id, now: now)
            reconnectSurface(of: pane)
            reconnectedIDs.insert(pane.id)
        }
        guard !reconnectedIDs.isEmpty else { return }
        let count = reconnectedIDs.count
        logger.info("reconnect(\(trigger.rawValue, privacy: .public)): respawning \(count, privacy: .public) dropped remote pane(s)")
        // Panes in non-visible tabs have no live SwiftUI container to answer
        // the reattach tick; a destroyed pane now matches the incubator's
        // `surface == nil` guard, so the normal warm path respawns them
        // off-screen (panesToWarm skips the active tab, whose panes rebuild
        // through the tick).
        warmFocusedProject()
        // The rebuild replaced the focused pane's NSView, so first responder
        // points at a retired view. Same async window fallback as
        // focusPane(_:): the sweep can run while the app is not yet active.
        if let tab = ws.activeTab, let focusedID = tab.focusedPaneID,
           reconnectedIDs.contains(focusedID)
        {
            DispatchQueue.main.async {
                let window = NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? (NSApp.delegate as? AppDelegate)?.mainWindow
                FocusRestoration.restoreFocus(to: focusedID, in: tab.splitRoot, window: window)
            }
        }
    }

    /// Rebuild one pane's surface in place, WITHOUT killing its zmx session —
    /// the session is the reattach target. Ordering is load-bearing:
    /// `destroySurface` nils `onProcessExit` first (so the dead surface can't
    /// race a `requestClosePane` at us mid-rebuild) and retires the old
    /// NSView; the reattach tick then makes `TerminalSurface.updateNSView`
    /// run `ensureScrollView` → `attach` → `configure` (reinstalling the
    /// callbacks the destroy just nil'd) → `createSurface`, which re-dials
    /// ssh against the same persisted session name.
    private func reconnectSurface(of pane: Pane) {
        pane.destroySurface()
        pane.requestSurfaceReattach()
    }

    // MARK: - Orphan session sweep (#281)

    /// Throttle key for the local daemon's slot in `sweptDestinations` —
    /// contains a character `RemoteSpawn.destination` can never produce.
    private static let localSweepKey = "<local>"
    /// Floor between sweeps of one destination. Project switches are cheap
    /// and frequent; orphan creation is rare, so once per app run is the
    /// intent and this just lets a long-lived run catch up eventually.
    private static let orphanSweepInterval: TimeInterval = 600

    /// Every session name a live or restored pane claims, across ALL
    /// workspaces — the reapers' spare list. Over-sparing is safe;
    /// under-sparing kills a live session, hence the `loadFailed` gates.
    /// Pinned live snapshots that haven't materialized yet count as claims
    /// too (#285), or a sweep would kill the very sessions the materialize
    /// step is about to reattach.
    private func claimedSessionNames() -> Set<String> {
        Set(workspaces.values
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
            .map(\.sessionName))
            .union(pendingPinnedSessionNames())
    }

    private func shouldSweep(_ destination: String, now: Date) -> Bool {
        if let last = sweptDestinations[destination],
           now.timeIntervalSince(last) < Self.orphanSweepInterval
        {
            return false
        }
        sweptDestinations[destination] = now
        return true
    }

    /// Reap orphaned zmx sessions on project selection (#281): the local
    /// daemon sweep that used to run only at launch, plus — for a remote
    /// project — the labelled sweep of its host. A remote session is orphaned
    /// when its kill silently no-op'd (`killRemoteSession` is best-effort:
    /// closing a pane while the host is unreachable leaves the session
    /// running with nobody tracking it); the sweep stamps
    /// `macterm.owner=<installationID>` on every session our panes claim and
    /// kills only sessions that carry OUR stamp, have zero clients, and no
    /// pane claims — so another machine's sessions on a shared host are
    /// structurally out of reach. Fail-closed at every layer: a failed
    /// snapshot load sweeps nothing, a failed probe reaps nothing, and the
    /// whole remote half sits behind `backgroundSSHConnections` (#272 — this
    /// is exactly the background connection that switch governs).
    func sweepOrphanSessions(project: Project) {
        // The hosted unit-test suite calls `selectProject` on AppStates whose
        // `zmx` defaults to `.live`, and its claim set is near-empty — a real
        // sweep would reap the developer's own detached sessions.
        guard !Preferences.isTestRun else { return }
        guard !workspaceStore.loadFailed else { return }
        let now = Date()
        let known = claimedSessionNames()
        if shouldSweep(Self.localSweepKey, now: now) {
            Task { [zmx] in await zmx.reapOrphans(knownSessionNames: known) }
        }
        guard Preferences.shared.backgroundSSHConnections,
              let remote = ProjectPath.remote(from: project.path),
              case let .remote(user, host, _) = remote
        else { return }
        let destination = RemoteSpawn.destination(user: user, host: host)
        guard shouldSweep(destination, now: now) else { return }
        // Stamp only the sessions OUR panes claim on this host — the safety
        // property that makes the owner label meaningful.
        let claimed = workspaces.values
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
            .filter { pane in
                guard case let .remote(paneUser, paneHost, _) = pane.remoteSpec else { return false }
                return RemoteSpawn.destination(user: paneUser, host: paneHost) == destination
            }
            .map(\.sessionName)
        let ownerID = Preferences.shared.installationID
        let zmxPath = project.zmxPath
        Task { [zmx] in
            guard let entries = await zmx.sweepRemoteOrphans(remote, zmxPath, claimed, ownerID)
            else { return }
            let orphans = ZmxReaper.orphans(in: entries, known: known, owner: ownerID)
            guard !orphans.isEmpty else { return }
            logger.info("Reaping \(orphans.count, privacy: .public) orphan remote session(s) on \(destination, privacy: .public)")
            for name in orphans {
                await zmx.killRemoteSession(remote, name, zmxPath)
            }
        }
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
        case .emptyTabs,
             .none:
            break
        }
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
        // The pinned workspace is never unloaded wholesale — pinned tabs are
        // the durable thing; a tab only unloads when its own sessions die.
        guard projectID != PinnedTabs.projectID else { return }
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
        unloadedProjectIDs.insert(projectID)
        if activeProjectID == projectID { activeProjectID = nil }
        saveWorkspaces()
    }

    /// Whether the project sits in the unloaded state `unloadProject(_:)`
    /// leaves behind — its tabs are a layout with no shells behind them.
    func isProjectUnloaded(_ projectID: UUID) -> Bool {
        unloadedProjectIDs.contains(projectID)
    }

    /// The teardown half of `removeProject`, without the workspace save — so
    /// a bulk removal can persist once for the whole batch instead of
    /// re-serializing the snapshot per item.
    private func removeProjectWithoutSaving(_ projectID: UUID) {
        // Unreachable through the UI (the sentinel is not a Project) — hard
        // guard so no future caller can tear the pinned workspace down.
        guard projectID != PinnedTabs.projectID else { return }
        logger.debug("removeProject: \(projectID, privacy: .public)")
        if let ws = workspaces[projectID] {
            for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
                // Project removed for good → its sessions die with it.
                pane.killPersistentSession(using: zmx)
                pane.destroySurface()
            }
        }
        workspaces.removeValue(forKey: projectID)
        unloadedProjectIDs.remove(projectID)
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
        var host: DialogHost = .mainWindow
    }

    var pendingUnloadProject: PendingUnloadProject?

    /// Unload a project, confirming first when any pane is busy.
    func requestUnloadProject(_ projectID: UUID, host: DialogHost = .mainWindow) {
        let busy = workspaces[projectID]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .contains(where: \.needsConfirmClose) ?? false
        if busy {
            pendingUnloadProject = PendingUnloadProject(projectID: projectID, host: host)
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
    func requestRemoveProject(_ projectID: UUID, host: DialogHost = .mainWindow, removal: @escaping () -> Void) {
        let busy = workspaces[projectID]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .contains(where: \.needsConfirmClose) ?? false
        if busy {
            pendingRemoveProject = PendingRemoveProject(projectID: projectID, completeRemoval: removal, host: host)
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
                .contains(where: \.needsConfirmClose) ?? false
            if busy { return true }
        }
        for tab in tabs {
            let busy = workspaces[tab.projectID]?.tabs
                .first { $0.id == tab.tabID }?
                .splitRoot.allPanes()
                .contains(where: \.needsConfirmClose) ?? false
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
    /// not whatever cwd the last pane drifted to. A new tab in the PINNED
    /// workspace (no project directory) starts at home; it's pinned from
    /// birth — `saveWorkspaces` gives it a record.
    func createTab(projectID: UUID, projects: [Project]) {
        if projectID == PinnedTabs.projectID {
            createTab(projectID: projectID, projectPath: PinnedTabs.fallbackRoot)
            return
        }
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        createTab(projectID: projectID, projectPath: project.path)
    }

    /// The teardown half of `closeTab`, without the workspace save — so a
    /// bulk close can persist once for the whole batch.
    private func closeTabWithoutSaving(_ tabID: UUID, projectID: UUID) {
        // Closing a PINNED tab is an unload, not a removal: sessions end, the
        // record (and its pinned.yaml entry) stays as a dimmed row, and the
        // next launch eager-starts it again. Unpin is the removal path.
        if projectID == PinnedTabs.projectID {
            unloadPinnedTab(tabID)
            return
        }
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
            .contains(where: \.needsConfirmClose) ?? false
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
        // The single selection seam: a pinned row may be UNLOADED (no live
        // tab), so pinned selection routes through the record-aware path —
        // every caller (sidebar, toolbar switcher, CLI) gets it for free.
        if projectID == PinnedTabs.projectID {
            selectPinnedTab(tabID)
            return
        }
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
        guard sourceProjectID != destProjectID else { return }
        // A move INTO the pinned workspace is a pin — route through `pinTab`
        // so the declaration is captured and the record inserted. This keeps
        // every drag/menu path a plain `moveTab` call.
        if destProjectID == PinnedTabs.projectID {
            pinTab(tabID, fromProject: sourceProjectID, toRecordIndex: toIndex)
            return
        }
        // An UNLOADED pinned record has no live tab for the guard below to
        // find; dragging its dimmed row into a project is still an unpin —
        // the drop names where it should spawn. Checked BEFORE the live-tab
        // guard, which would otherwise bail first.
        if sourceProjectID == PinnedTabs.projectID,
           workspaces[sourceProjectID]?.tabs.contains(where: { $0.id == tabID }) != true,
           let record = pinnedRecord(tabID)
        {
            unpinUnloadedRecord(record, toProject: destProjectID, toIndex: toIndex)
            return
        }
        guard let source = workspaces[sourceProjectID],
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
        // A move OUT of the pinned workspace is the unpin: the record (and
        // its `pinned.yaml` entry) goes with it.
        if sourceProjectID == PinnedTabs.projectID {
            removePinnedRecord(forTab: tabID)
        }
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Merge a tab into the destination project's ACTIVE tab at a resolved
    /// workspace drop target (#227 — dragging a sidebar tab into the
    /// workspace, where the cursor picks a level: whole-edge, divider, or
    /// local pane split). No-op when the active tab IS the dragged tab.
    func mergeTab(
        _ tabID: UUID,
        from sourceProjectID: UUID,
        at target: TabDropResolution.Target,
        inProject destProjectID: UUID
    ) {
        guard let destTab = workspaces[destProjectID]?.activeTab,
              destTab.id != tabID,
              let sourceTab = detachTabForMerge(tabID, from: sourceProjectID, to: destProjectID)
        else { return }
        guard destTab.mergeTree(sourceTab.splitRoot, at: target) else {
            // The target pane vanished mid-drag: put the detached tab back
            // (identity restored) instead of losing its live shells.
            if sourceProjectID != destProjectID {
                for pane in sourceTab.splitRoot.allPanes() {
                    pane.rebind(projectID: sourceProjectID)
                }
            }
            workspaces[sourceProjectID]?.adoptTab(sourceTab)
            saveWorkspaces()
            return
        }
        finishMerge(intoTab: destTab.id, inProject: destProjectID)
    }

    /// Pull a tab out of its workspace for a merge, keeping its panes (and
    /// their surfaces) alive, and restamp their routing identity when the merge
    /// crosses projects — the same rebind `moveTab` does, for the same reason.
    private func detachTabForMerge(_ tabID: UUID, from sourceProjectID: UUID, to destProjectID: UUID) -> TerminalTab? {
        guard let source = workspaces[sourceProjectID],
              let tab = source.tabs.first(where: { $0.id == tabID })
        else { return nil }
        source.closeTab(tabID)
        if sourceProjectID != destProjectID {
            for pane in tab.splitRoot.allPanes() {
                pane.rebind(projectID: destProjectID)
            }
            // Merging a pinned tab's tree into another project's tab unpins
            // it — the tab object dissolves into the destination.
            if sourceProjectID == PinnedTabs.projectID {
                removePinnedRecord(forTab: tabID)
            }
        }
        return tab
    }

    /// Land the user on the merged tab, mirroring `moveTab`'s selection.
    private func finishMerge(intoTab destTabID: UUID, inProject destProjectID: UUID) {
        workspaces[destProjectID]?.selectTab(destTabID)
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Split a tab apart (#227 — "Separate Panes"): every pane after the first
    /// (in tree order) moves into its own fresh tab inserted right after the
    /// source tab, and the source keeps only its first pane. The `Pane`
    /// objects are reused as-is, so surfaces and running shells survive.
    /// No-op for a single-pane tab.
    func separateTabPanes(_ tabID: UUID, projectID: UUID) {
        guard let ws = workspaces[projectID],
              let index = ws.tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        let tab = ws.tabs[index]
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1, let firstPane = panes.first else { return }
        logger.debug("separateTabPanes: \(tabID, privacy: .public) panes=\(panes.count, privacy: .public)")
        tab.splitRoot = .pane(firstPane)
        tab.zoomedPaneID = nil
        tab.paneFocusHistory = RecencyStack(limit: 20)
        tab.focusedPaneID = firstPane.id
        for (offset, pane) in panes.dropFirst().enumerated() {
            let newTab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
            ws.tabs.insert(newTab, at: index + 1 + offset)
        }
        ws.selectTab(tabID)
        saveWorkspaces()
    }

    /// Split a single pane out of its tab into its own fresh tab — the
    /// per-pane sibling of `separateTabPanes` ("Separate Current Pane"). The
    /// `Pane` object is reused as-is, so its surface and running shell
    /// survive; the source tab keeps its remaining panes. `index` is the
    /// slot in the destination project's tab list (nil appends). Crossing
    /// projects rebinds the pane's routing identity, mirroring `moveTab`.
    /// No-op when the pane isn't in any workspace or is its tab's only pane
    /// (already its own tab).
    func separatePane(_ paneID: UUID, toProject destProjectID: UUID, destPath: String, at index: Int? = nil) {
        guard let (sourceProjectID, sourceTab) = locatePane(paneID),
              sourceTab.splitRoot.allPanes().count > 1,
              let pane = sourceTab.splitRoot.findPane(id: paneID)
        else { return }
        // Resolve the destination before detaching, so a failure can't leave
        // the pane belonging to no tab.
        ensureWorkspace(projectID: destProjectID, path: destPath)
        guard let dest = workspaces[destProjectID],
              let remaining = sourceTab.splitRoot.removing(paneID: paneID)
        else { return }
        logger.debug(
            "separatePane: \(paneID, privacy: .public) to=\(destProjectID, privacy: .public) index=\(index ?? -1, privacy: .public)"
        )
        // Detach without destroying: the same tree/zoom/focus repair as
        // `removePane`, minus the surface teardown — the pane lives on.
        sourceTab.splitRoot = remaining
        if sourceTab.zoomedPaneID == paneID { sourceTab.zoomedPaneID = nil }
        sourceTab.paneFocusHistory.remove(paneID)
        if sourceTab.focusedPaneID == paneID {
            sourceTab.focusedPaneID = sourceTab.nextFocusAfterClose()
        }
        if Preferences.shared.autoTilingEnabled { sourceTab.splitRoot.rebalanced() }

        if sourceProjectID != destProjectID {
            pane.rebind(projectID: destProjectID)
        }
        let newTab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        dest.adoptTab(newTab, at: index)
        activeProjectID = destProjectID
        recordProjectVisit(destProjectID)
        saveWorkspaces()
    }

    /// Find the workspace tab currently holding a pane. Scans every loaded
    /// workspace — a sidebar pane drop only carries the pane's id, and the
    /// quick terminal's ephemeral tab (not in `workspaces`) correctly misses.
    private func locatePane(_ paneID: UUID) -> (projectID: UUID, tab: TerminalTab)? {
        for (projectID, ws) in workspaces {
            if let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil }) {
                return (projectID, tab)
            }
        }
        return nil
    }

    /// Reorder a tab within its own project to an absolute drop index (the
    /// offset a sidebar drag-and-drop reports). Persists on a real move.
    func reorderTab(_ tabID: UUID, inProject projectID: UUID, toIndex destination: Int) {
        // A pinned reorder must move the RECORD (the sidebar rows and
        // pinned.yaml follow records, not the live-tab array) — the offset
        // arrives in live-tab space here, so translate it.
        if projectID == PinnedTabs.projectID {
            reorderPinnedLiveTab(tabID, toLiveIndex: destination)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.tabs.map(\.id)
        ws.moveTab(tabID, toIndex: destination)
        if ws.tabs.map(\.id) != before { saveWorkspaces() }
    }

    func selectNextTab(projectID: UUID) {
        // The pinned workspace cycles in RECORD order — unloaded rows
        // included, restored on landing — so the keyboard walks exactly what
        // the sidebar shows, not just the loaded subset.
        if projectID == PinnedTabs.projectID {
            cyclePinnedTab(step: 1)
            return
        }
        guard let ws = workspaces[projectID] else { return }
        let before = ws.activeTabID
        let didAcknowledgeCompletion = ws.selectNextTab()
        if ws.activeTabID != before || didAcknowledgeCompletion {
            saveWorkspaces()
        }
    }

    func selectPreviousTab(projectID: UUID) {
        if projectID == PinnedTabs.projectID {
            cyclePinnedTab(step: -1)
            return
        }
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
        // Pinned rows cycle first (they sit at the top of the sidebar), in
        // RECORD order — unloaded records included, so keyboard cycling can
        // land on (and restore) a dead pinned tab exactly like clicking it.
        let pinnedEntries: [(projectID: UUID, tabID: UUID)] = pinnedRecords.map { (PinnedTabs.projectID, $0.id) }
        let projectEntries: [(projectID: UUID, tabID: UUID)] = projects.flatMap { p in
            (workspaces[p.id]?.tabs ?? []).map { (p.id, $0.id) }
        }
        let allTabs = pinnedEntries + projectEntries
        guard !allTabs.isEmpty else { return }

        let currentTabID = activeProjectID.flatMap { pid in workspaces[pid]?.activeTabID }
        let currentIndex =
            allTabs.firstIndex { $0.projectID == activeProjectID && $0.tabID == currentTabID } ?? 0
        let newIndex: Int =
            switch direction {
            case .next: (currentIndex + 1) % allTabs.count
            case .previous: (currentIndex - 1 + allTabs.count) % allTabs.count
            }
        let entry = allTabs[newIndex]
        if entry.projectID == PinnedTabs.projectID {
            // Loads an unloaded record and persists on its own.
            selectPinnedTab(entry.tabID)
            return
        }
        guard let project = projects.first(where: { $0.id == entry.projectID }) else { return }
        let beforeProjectID = activeProjectID
        let beforeTabID = workspaces[project.id]?.activeTabID

        activeProjectID = project.id
        ensureWorkspace(projectID: project.id, path: project.path)
        let didAcknowledgeCompletion = workspaces[project.id]?.selectTab(entry.tabID) ?? false
        if activeProjectID != beforeProjectID
            || workspaces[project.id]?.activeTabID != beforeTabID
            || didAcknowledgeCompletion
        {
            saveWorkspaces()
        }
    }

    /// Tab slots addressable by Cmd+digit — sidebar ROWS in the pinned
    /// workspace (records, unloaded included) and live tabs elsewhere, the
    /// same two sources `selectTabByIndex` selects from. It is what bounds
    /// digit accumulation, so the two must keep counting the same things.
    func selectableTabCount(projectID: UUID) -> Int {
        if projectID == PinnedTabs.projectID { return pinnedRecords.count }
        return workspaces[projectID]?.tabs.count ?? 0
    }

    func selectTabByIndex(_ index: Int, projectID: UUID) {
        // Cmd+digit in the pinned workspace counts SIDEBAR rows (records,
        // unloaded included), matching what the user sees.
        if projectID == PinnedTabs.projectID {
            guard pinnedRecords.indices.contains(index) else { return }
            selectPinnedTab(pinnedRecords[index].id)
            return
        }
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
        // Closing a pinned tab's LAST pane closes the tab, which for a pinned
        // tab is an unload (record kept). Route it whole through closeTab so
        // the unload path tears the pane down itself — falling through to
        // removePane would destroy the surface first and leave unloadPinnedTab
        // double-tearing it (harmless but pointless).
        if projectID == PinnedTabs.projectID, tab.splitRoot.allPanes().count <= 1 {
            closeTab(tab.id, projectID: projectID)
            return
        }
        logger.debug("closePane: \(paneID, privacy: .public) project=\(projectID, privacy: .public)")
        // Pane closed for good → its zmx session dies with it. (The
        // onlyPaneLeft path below re-kills via closeTab; killSession is a
        // no-op on a missing session, so the overlap is harmless.)
        tab.splitRoot.findPane(id: paneID)?.killPersistentSession(using: zmx)
        reconnectPolicy.forget(paneID)
        switch tab.removePane(paneID) {
        case .onlyPaneLeft:
            closeTab(tab.id, projectID: projectID)
        case .removed:
            saveWorkspaces()
        case .notFound:
            break
        }
    }

    /// A pane's child process ended (libghostty's `close_surface`, routed
    /// through `onProcessExit`). Local panes close, as always — via
    /// `paneProcessExited`, so a pinned tab's last pane unloads its tab
    /// instead (#285). A REMOTE
    /// pane's child is its ssh client, and WHY it ended decides (#281):
    /// a deliberate end (the user typed `exit`, ending the zmx session, or
    /// killed it) should close the pane as before, while a dropped
    /// connection must NOT — libghostty has already rendered its exit
    /// message into the still-live surface, the session lives on host-side,
    /// and the reconnect sweep redials it on the next trigger. Closing
    /// unconditionally was the pre-#281 behavior, and because `closePane`
    /// kills the pane's session, a wake-time ssh death destroyed the remote
    /// work the moment the network came back.
    ///
    /// The discriminator is the HOST's answer, not the exit code — measured
    /// on macOS the exit code is always 0 (ghostty's own Surface.zig notes
    /// exit-code detection doesn't work on Darwin), so a one-shot BatchMode
    /// listing settles it: session gone → deliberate end → close; session
    /// alive or host unreachable → drop → keep. Fail-safe by construction:
    /// wrongly keeping a pane costs a manual close, wrongly closing one
    /// costs the user's running session. With `backgroundSSHConnections`
    /// off (#272) no probe is allowed, so every remote exit keeps the pane.
    func handleProcessExit(_ paneID: UUID, projectID: UUID) {
        let pane = workspaces[projectID]?.tabs
            .compactMap { $0.splitRoot.findPane(id: paneID) }
            .first
        guard let pane, pane.isRemote, let remote = pane.remoteSpec else {
            paneProcessExited(paneID, projectID: projectID)
            return
        }
        guard Preferences.shared.backgroundSSHConnections else {
            logger.info("remote pane ssh ended; probes disabled — keeping pane as disconnected")
            return
        }
        let sessionName = pane.sessionName
        let zmxPath = pane.remoteZmxPath
        let ownerID = Preferences.shared.installationID
        Task { [zmx, weak self] in
            // The stamp-then-list op doubles as the liveness probe (stamping
            // our own claimed session is what the sweep does anyway).
            let entries = await zmx.sweepRemoteOrphans(remote, zmxPath, [sessionName], ownerID)
            guard let entries else {
                logger.info("remote pane ssh ended; host unreachable — keeping pane as disconnected")
                return
            }
            guard !entries.contains(where: { $0.name == sessionName }) else {
                logger.info("remote pane ssh ended but its session lives — keeping pane as disconnected")
                return
            }
            guard let self else { return }
            // Session is gone: deliberate end. Close — unless something
            // (a reconnect trigger racing this probe) already revived the
            // pane with a live child.
            if let view = self.workspaces[projectID]?.tabs
                .compactMap({ $0.splitRoot.findPane(id: paneID) })
                .first?.nsView, view.surface != nil, !view.processExited
            {
                return
            }
            logger.info("remote pane ssh ended and its session is gone — closing the pane")
            // A pinned tab's last pane unloads the tab rather than closing
            // it (#285); everywhere else this is a plain close (the session
            // is already gone, so no confirmation applies).
            if projectID == PinnedTabs.projectID {
                self.paneProcessExited(paneID, projectID: projectID)
            } else {
                self.closePane(paneID, projectID: projectID)
            }
        }
    }

    func requestClosePane(_ paneID: UUID, projectID: UUID) {
        let pane = workspaces[projectID]?.tabs
            .compactMap { $0.splitRoot.findPane(id: paneID) }
            .first
        if pane?.needsConfirmClose == true {
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
    func applyLayout(project: Project, host: DialogHost = .mainWindow) -> Error? {
        logger.info("applyLayout: project=\(project.name, privacy: .public)")
        let layout: LayoutFile
        do {
            guard let file = try projectFiles.loadFull(
                forProjectPath: project.path,
                preferredSlug: ProjectSlug.slug(from: project.name)
            )
            else {
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
            pendingLayoutApply = PendingLayoutApply(projectID: project.id, plan: plan, host: host)
        } else {
            executeLayoutPlan(plan, projectID: project.id)
        }
        return nil
    }

    /// `applyLayout` + error presentation: failures land in
    /// `pendingLayoutError` (the alert in `MactermApp`). The shared entry
    /// point for the palette/menu command and the first-open auto-apply.
    ///
    /// `confirming` marks the *user-invoked* command (palette, menu, keybind),
    /// which gets a success toast. The first-open seed passes false: it fires
    /// unbidden on every project's first open, where a confirmation would be
    /// noise for something the user never asked for.
    func applyLayoutPresentingError(_ project: Project, confirming: Bool = false, host: DialogHost = .mainWindow) {
        if let error = applyLayout(project: project, host: host) {
            pendingLayoutError = LayoutError(verb: "apply", message: error.localizedDescription, host: host)
            return
        }
        // A destructive plan is staged, not applied — its confirmation dialog is
        // up, and the toast belongs to whatever the user chooses there
        // (`confirmPendingLayoutApply`), not to merely opening the prompt.
        if confirming, pendingLayoutApply == nil {
            presentToast("Layout applied")
        }
    }

    func confirmPendingLayoutApply() {
        guard let pending = pendingLayoutApply else { return }
        pendingLayoutApply = nil
        executeLayoutPlan(pending.plan, projectID: pending.projectID)
        // Always user-invoked: reaching here means they clicked through the
        // destructive-apply confirmation.
        presentToast("Layout applied")
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
    func saveLayout(project: Project, siblingProjects: [Project] = [], host: DialogHost = .mainWindow) -> Error? {
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
            // This is the app writing a project file — an open Projects
            // settings pane must re-read the directory or it shows the
            // pre-save state.
            noteLayoutFilesChanged()
            // A stray-*file* conflict (an unrelated file declares this path)
            // takes priority over the shared-*project* notice — both write
            // `pendingLayoutError`, so only surface the latter when the former
            // stayed quiet.
            if !presentSaveConflictIfNeeded(
                project: project,
                savedTo: target,
                siblingProjects: siblingProjects,
                host: host
            ) {
                presentSharedPathConflictIfNeeded(
                    project: project,
                    savedTo: target,
                    siblingProjects: siblingProjects,
                    host: host
                )
            }
            // Confirm the clean save only. Either conflict check above raises a
            // dialog that says the file landed *and* what's wrong with it — a
            // cheerful "Layout saved" stacked on top would undercut it.
            //
            // The subtitle is the full path, home-contracted: the projects
            // directory isn't somewhere the user necessarily has in mind, so a
            // bare filename doesn't tell them where to go look. `~` keeps it
            // readable (and keeps the username out of a screenshot).
            if pendingLayoutError == nil {
                presentToast("Layout saved", subtitle: ProjectPath.homeContracted(target.path))
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
    private func presentSaveConflictIfNeeded(
        project: Project,
        savedTo target: URL,
        siblingProjects: [Project],
        host: DialogHost
    ) -> Bool {
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
            customTitle: "Layout saved with a conflict",
            host: host
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
    private func presentSharedPathConflictIfNeeded(
        project: Project,
        savedTo target: URL,
        siblingProjects: [Project],
        host: DialogHost
    ) {
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
            customTitle: "Layout file shared with another project",
            host: host
        )
    }

    /// `saveLayout` + error presentation, mirroring `applyLayoutPresentingError`.
    func saveLayoutPresentingError(
        _ project: Project,
        siblingProjects: [Project] = [],
        host: DialogHost = .mainWindow
    ) {
        if let error = saveLayout(project: project, siblingProjects: siblingProjects, host: host) {
            pendingLayoutError = LayoutError(verb: "save", message: error.localizedDescription, host: host)
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

    /// Publish presentation-only renderer state through the workspace owner.
    /// The color is transient and therefore does not trigger persistence.
    func setAdaptiveBackgroundColor(_ color: CGColor?, paneID: UUID, projectID: UUID) {
        guard let pane = workspaces[projectID]?.tabs
            .lazy
            .compactMap({ $0.splitRoot.findPane(id: paneID) })
            .first,
            pane.adaptiveBackgroundColor != color
        else { return }
        pane.adaptiveBackgroundColor = color
    }

    /// Begin the sidebar rename flow for the tab containing `paneID` — the
    /// ghostty `prompt_surface_title` keybind's Macterm mapping (titles live
    /// on tabs here, not surfaces). No-op for panes outside any workspace
    /// (the quick terminal has no tab UI to rename).
    func renameTab(containing paneID: UUID, projectID: UUID) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        sidebarVisible = true
        let tabID = tab.id
        // Defer a tick so the sidebar row's TextField exists before it's asked
        // to begin editing — same reason as the Rename Tab command.
        DispatchQueue.main.async { self.renamingTabID = tabID }
    }

    /// Set (or, with nil, clear) the custom title of the tab containing
    /// `paneID` — the ghostty `set_tab_title` keybind's Macterm mapping,
    /// writing the same field the sidebar rename edits.
    func setTabTitle(containing paneID: UUID, projectID: UUID, title: String?) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.splitRoot.contains(paneID: paneID) })
        else { return }
        tab.customTitle = title
        saveWorkspaces()
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
        stepProject(1, projects: projects)
    }

    func selectPreviousProject(projects: [Project]) {
        stepProject(-1, projects: projects)
    }

    /// Project cycling treats the pinned workspace as a slot ABOVE the first
    /// project (where the sidebar draws it) — without it, the keyboard could
    /// enter the pinned section but never leave it.
    private func stepProject(_ step: Int, projects: [Project]) {
        var slots = projects.map(\.id)
        if !pinnedRecords.isEmpty {
            slots.insert(PinnedTabs.projectID, at: 0)
        }
        guard slots.count > 1, let current = activeProjectID,
              let i = slots.firstIndex(of: current)
        else { return }
        let target = slots[(i + step + slots.count) % slots.count]
        if target == PinnedTabs.projectID {
            selectPinnedProject()
        } else if let project = projects.first(where: { $0.id == target }) {
            selectProject(project)
        }
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
        // Looking at the active tab acknowledges completion for the whole tab,
        // not only its focused pane. Otherwise a non-focused split pane that
        // finished a command stays `.done` under the hood, gets persisted, and
        // reappears as a status dot after the user switches away or restarts.
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
        // The pinned workspace starts EMPTY — the path-taking init spawns an
        // initial tab, which nobody pinned.
        if projectID == PinnedTabs.projectID {
            ensurePinnedWorkspace()
            return
        }
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, projectPath: path)
        }
    }
}
