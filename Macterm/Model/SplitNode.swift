import CoreGraphics
import Foundation

enum SplitDirection: String, Codable { case horizontal, vertical }
enum SplitPosition { case first, second }

/// Which edge of a pane a dragged pane is dropped onto. Determines how the
/// destination is split and on which side the dragged pane lands.
enum PaneDropZone: Equatable {
    case left
    case right
    case top
    case bottom

    /// The drop zone for a cursor position inside a pane: the four triangular
    /// regions formed by the pane's diagonals, i.e. whichever edge is closest.
    static func calculate(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .right }
        let distToLeft = point.x / size.width
        let distToRight = 1 - distToLeft
        let distToTop = point.y / size.height
        let distToBottom = 1 - distToTop
        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)
        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    var splitDirection: SplitDirection {
        switch self {
        case .left,
             .right: .horizontal
        case .top,
             .bottom: .vertical
        }
    }

    var splitPosition: SplitPosition {
        switch self {
        case .left,
             .top: .first
        case .right,
             .bottom: .second
        }
    }
}

enum TerminalExecutionState: Equatable {
    case idle
    case running
    case done
}

private struct ForegroundProcessKey: Equatable {
    let name: String
    let pid: pid_t?

    init?(name: String?, pid: pid_t?) {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalizedName.isEmpty else { return nil }
        self.name = normalizedName
        self.pid = pid
    }
}

private enum TerminalExecutionSource: Equatable {
    case foreground
    case activity(Date)
    case progress
}

struct TerminalExecutionTracker {
    private enum PendingOutputStart {
        case armed(Date)
        case candidate(Date)
    }

    private static let submissionWindow: TimeInterval = 2

    init(hasUserInteraction: Bool = false) {
        self.hasUserInteraction = hasUserInteraction
    }

    /// The foreground process seen on the last poll (nil = idle shell / none).
    /// Transitions are driven by *changes* to this, not by re-deriving state on
    /// every poll — so a settled process doesn't flip-flop back to running just
    /// because it is still foreground.
    private var lastForeground: ForegroundProcessKey?
    /// Last observed tty input mode for `lastForeground`. Mode transitions are
    /// meaningful even when the pid/name key is unchanged.
    private var lastTerminalInputWasRaw: Bool?
    /// Why the pane is currently considered running. Foreground and explicit
    /// progress run until a completion/foreground transition; activity is an
    /// output heartbeat and quiet-settles.
    private var runningSource: TerminalExecutionSource?
    /// After progress clears, the foreground process that owned it is
    /// "quiesced": its own output and re-polls are ignored until the foreground
    /// moves away. `pendingProgressQuiesce` covers progress that starts and
    /// clears before any foreground poll.
    private var progressQuiesced: ForegroundProcessKey?
    private var pendingProgressQuiesce = false
    /// Startup output is ignored until the pane has received user input (or a
    /// declarative `run:`, which seeds this at initialization).
    private var hasUserInteraction = false
    /// Geometry baseline carried by the IO-path output heartbeat. Growth is
    /// strong activity evidence; equal totals describe an in-place redraw.
    private var lastOutputRows: UInt64?
    /// A narrowly-armed path for work nested inside a recognized AI agent. The
    /// first in-place output heartbeat is only a candidate; a second within the
    /// submission window confirms sustained work.
    private var pendingOutputStart: PendingOutputStart?
    /// A forwarded Return with no committed prompt text can still make a TUI
    /// redraw or grow rows. Suppress those start signals briefly so an empty
    /// submission cannot flash the spinner.
    private var blankSubmissionAt: Date?

    var isActivitySourced: Bool {
        if case .activity = runningSource { return true }
        return false
    }

    mutating func recordUserInteraction() {
        hasUserInteraction = true
        // Typing, scrolling, or any other interaction after Return means later
        // redraws can no longer be attributed to that submission.
        pendingOutputStart = nil
    }

    mutating func recordCommandSubmission(
        at date: Date,
        allowInPlaceOutputStart: Bool,
        hasContent: Bool
    ) {
        hasUserInteraction = true
        guard hasContent else {
            pendingOutputStart = nil
            blankSubmissionAt = date
            return
        }
        // A deliberate nonempty submission supersedes a process quiesced by an
        // earlier progress report, even when a long-lived TUI retains its pid.
        progressQuiesced = nil
        pendingProgressQuiesce = false
        blankSubmissionAt = nil
        pendingOutputStart = allowInPlaceOutputStart ? .armed(date) : nil
    }

    mutating func markProgressStarted(currentState: TerminalExecutionState) -> TerminalExecutionState {
        pendingOutputStart = nil
        blankSubmissionAt = nil
        guard hasUserInteraction else { return currentState }
        runningSource = .progress
        return .running
    }

    mutating func markCommandFinished(currentState: TerminalExecutionState) -> TerminalExecutionState {
        // Shell integration (OSC 133;D) fires on every precmd, including an
        // empty Return. Always cancel its submission candidate, but only show a
        // completion when a command was genuinely running.
        pendingOutputStart = nil
        // OSC 133;D for an empty Return may arrive before its redraw/output.
        // Keep blank suppression while idle so that later callback cannot flash
        // the spinner; a genuine running completion no longer needs it.
        guard currentState == .running else { return currentState }
        blankSubmissionAt = nil
        runningSource = nil
        progressQuiesced = nil
        pendingProgressQuiesce = false
        return .done
    }

    mutating func markProgressFinished(currentState: TerminalExecutionState) -> TerminalExecutionState {
        pendingOutputStart = nil
        blankSubmissionAt = nil
        guard hasUserInteraction || runningSource == .progress else { return currentState }
        if let lastForeground {
            progressQuiesced = lastForeground
        } else {
            pendingProgressQuiesce = true
        }
        runningSource = nil
        return currentState == .running ? .done : currentState
    }

    mutating func markTerminalActivity(
        at date: Date,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        // Output may start an idle, interacted-with pane or sustain an
        // activity-owned run. It must not resurrect `.done`, override explicit
        // progress, or demote a canonical foreground command into a run that
        // quiet-settles while its process is still alive.
        guard currentState != .done else { return currentState }
        guard !shouldSuppressOutputStart(at: date, currentState: currentState) else { return currentState }
        guard runningSource != .progress else { return currentState }
        guard runningSource != .foreground else { return currentState }
        if let progressQuiesced, progressQuiesced == lastForeground { return currentState }
        guard hasUserInteraction else { return currentState }
        pendingOutputStart = nil
        runningSource = .activity(date)
        return .running
    }

    /// Handle an occlusion-independent, throttled heartbeat from libghostty's
    /// pty IO path. Scrollback growth is strong evidence and follows the normal
    /// activity guards. Equal row totals only sustain an activity-owned run,
    /// except for two heartbeats immediately following an explicitly armed
    /// agent submission (the same-raw-pid Pi `! sleep` case).
    mutating func markOutputActivity(
        totalRows: UInt64,
        at date: Date,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        let grew = lastOutputRows.map { totalRows > $0 } ?? false
        lastOutputRows = totalRows
        if grew {
            return markTerminalActivity(at: date, currentState: currentState)
        }

        if currentState == .running, case .activity = runningSource {
            pendingOutputStart = nil
            runningSource = .activity(date)
            return currentState
        }

        guard currentState == .idle else {
            pendingOutputStart = nil
            return currentState
        }
        guard hasUserInteraction else { return currentState }
        guard runningSource != .progress else { return currentState }
        if let progressQuiesced, progressQuiesced == lastForeground { return currentState }

        switch pendingOutputStart {
        case let .armed(submittedAt):
            guard isWithinSubmissionWindow(date, submittedAt: submittedAt) else {
                pendingOutputStart = nil
                return currentState
            }
            pendingOutputStart = .candidate(submittedAt)
            return currentState
        case let .candidate(submittedAt):
            guard isWithinSubmissionWindow(date, submittedAt: submittedAt) else {
                pendingOutputStart = nil
                return currentState
            }
            pendingOutputStart = nil
            runningSource = .activity(date)
            return .running
        case nil:
            return currentState
        }
    }

    private func isWithinSubmissionWindow(_ date: Date, submittedAt: Date) -> Bool {
        let elapsed = date.timeIntervalSince(submittedAt)
        return elapsed >= 0 && elapsed < Self.submissionWindow
    }

    private mutating func shouldSuppressOutputStart(
        at date: Date,
        currentState: TerminalExecutionState
    ) -> Bool {
        guard currentState == .idle, let blankSubmissionAt else { return false }
        if isWithinSubmissionWindow(date, submittedAt: blankSubmissionAt) { return true }
        self.blankSubmissionAt = nil
        return false
    }

    mutating func settleIfQuiet(
        now: Date,
        quietInterval: TimeInterval,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        guard currentState == .running,
              case let .activity(lastActivityAt) = runningSource,
              now.timeIntervalSince(lastActivityAt) >= quietInterval
        else { return currentState }
        runningSource = nil
        pendingOutputStart = nil
        blankSubmissionAt = nil
        return .done
    }

    /// Restart the quiet window of an activity-sourced run. Used only by the
    /// compatibility path for surfaces that have not proven they receive the
    /// occlusion-independent heartbeat.
    mutating func refreshActivityWindow(now: Date) {
        guard case .activity = runningSource else { return }
        runningSource = .activity(now)
    }

    mutating func refreshForeground(
        name: String?,
        pid: pid_t?,
        foregroundIsShell: Bool,
        terminalInputIsRaw: Bool,
        at date: Date = Date(),
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        let newKey = foregroundIsShell ? nil : ForegroundProcessKey(name: name, pid: pid)
        let changed = newKey != lastForeground
        let returnedToCanonical = !changed
            && lastTerminalInputWasRaw == true
            && !terminalInputIsRaw
        lastTerminalInputWasRaw = newKey == nil ? nil : terminalInputIsRaw
        // An authoritative process transition supersedes output heuristics. A
        // steady raw Pi pid deliberately preserves the submission candidate.
        if changed {
            pendingOutputStart = nil
            blankSubmissionAt = nil
        }

        // Resolve the race where progress cleared before a foreground poll: the
        // first process is quiesced rather than immediately restarted.
        if pendingProgressQuiesce {
            if let newKey {
                progressQuiesced = newKey
                pendingProgressQuiesce = false
                lastForeground = newKey
                return currentState
            }
            pendingProgressQuiesce = false
        }

        // A different foreground process releases progress quiescing.
        if let progressQuiesced, progressQuiesced != newKey {
            self.progressQuiesced = nil
        }

        lastForeground = newKey

        // Returning to the shell is the authoritative completion edge for a
        // foreground command, regardless of whether it was later demoted to
        // activity ownership by a canonical→raw transition.
        if newKey == nil {
            guard changed, currentState == .running else { return currentState }
            runningSource = nil
            return .done
        }

        // Explicit progress owns state while active. Startup foreground noise
        // remains ignored until the pane has received trusted input.
        if runningSource == .progress { return currentState }
        guard hasUserInteraction else { return currentState }

        if terminalInputIsRaw {
            // A TUI switching canonical→raw is still working. Demote its
            // foreground-owned run so IO heartbeats keep it alive and quiet
            // output can settle it, rather than marking it done immediately.
            if currentState == .running, runningSource == .foreground {
                runningSource = .activity(date)
            }
            return currentState
        }

        // A same-pid TUI can return from raw to canonical mode while it keeps
        // working. Restore foreground authority only while it is still
        // running; a same-pid process that already quiet-settled must not be
        // resurrected by a later poll.
        if returnedToCanonical, currentState == .running,
           case .activity = runningSource
        {
            runningSource = .foreground
            return currentState
        }

        // A canonical non-shell command is foreground-owned until its process
        // changes. Re-polls of the same pid must not restart settled state.
        guard changed else { return currentState }
        runningSource = .foreground
        return .running
    }
}

/// A pane is the leaf of the split tree — one terminal surface.
@MainActor @Observable
final class Pane: Identifiable {
    let id = UUID()
    let projectPath: String
    /// The workspace this pane currently belongs to — the ROUTING identity used
    /// to locate the pane's tab (notification-click navigation bakes this into
    /// `userInfo`; the quit sweep groups panes by it). Restampable because a tab
    /// can be moved between projects (`AppState.moveTab`); `rebind(projectID:)`
    /// updates it. Distinct from SESSION identity (`sessionName`/`sessionSlug`/
    /// `projectPath`/`remoteSpec`), which stays tied to where the session was
    /// created and must NOT change on a move — the shell keeps running on its
    /// original host under its original name.
    private(set) var projectID: UUID
    /// Stable session id for zmx-backed persistence, distinct from `id` (which
    /// is regenerated on every restore). Fresh for a new pane; the restore
    /// path will pass the saved one.
    let sessionID: UUID
    /// The pane's zmx session name (`macterm-<slug>-<hex>`), fixed at creation
    /// and — once persistence lands — stored verbatim in the snapshot, never
    /// re-derived: the slug embeds the project *at creation*, and a later
    /// project rename must not orphan the session. The slug comes from the
    /// project path's basename (which is the project's name for every project
    /// added from a folder); callers with a better label (quick terminal)
    /// pass `sessionSlug` explicitly, and splits inherit the source pane's.
    let sessionName: String
    /// The raw slug this pane's session was named under, so a split-off
    /// sibling groups under the same project in `zmx ls`.
    let sessionSlug: String
    /// Whether this pane's project is remote (#104) — its `projectPath` is an
    /// scp-style spec and its session lives on the remote host. Cached at
    /// init: the poll and title paths read it every tick.
    let isRemote: Bool
    /// The remote host name for display fallback (`processTitle` shows it
    /// while no remote process name is known). nil for local panes.
    let remoteHost: String?
    /// The parsed scp-style spec for a remote pane (`.remote(user,host,dir)`),
    /// or nil for a local pane. Cached at init so the spawn (`ensureNSView`)
    /// and teardown (`killPersistentSession`) paths don't re-parse
    /// `projectPath` — they read this instead.
    @ObservationIgnored
    let remoteSpec: ProjectPath?
    /// Optional explicit remote zmx path (#104), from the pane's `Project`.
    /// Not part of pane identity and not persisted — `AppState` stamps it from
    /// the project each time the workspace is built (it's a host property,
    /// re-derivable on every open). Read by `ensureNSView` (spawn) and
    /// `killPersistentSession` (teardown). nil = resolve `zmx` via PATH.
    @ObservationIgnored
    var remoteZmxPath: String?
    /// Process the pane launches on first surface creation, injected into the
    /// shell as `command + "\n"`. Set from a declarative layout; nil for an
    /// interactively-created pane (plain shell). Recorded here so a layout
    /// `apply` can match a live pane by its declared command even after the
    /// process has exited (see LayoutReconciler).
    let command: String?
    /// Shell binary to launch as the pane's program. nil → resolved from the
    /// ghostty config / login shell at surface-creation time.
    let shell: String?
    /// Extra environment variables for the spawned shell. nil/empty → none.
    let env: [String: String]?
    /// The basename of the pane's live foreground process — a running command
    /// (`hx`, `btop`), or the pane's shell when idle at a prompt (so a nested
    /// `zsh` launched inside `nu` shows `zsh`). nil only before the surface
    /// exists. This is the tab name's default source: it's read from the
    /// process table (`ProcessInspector`), so it's immune to the shell's
    /// prompt-title churn. Refreshed by `refreshForegroundProcess()`.
    var foregroundProcessName: String?

    /// A title a foreground *program* set via OSC 0/2 (claude's session
    /// summary, ssh's `user@host`). When present it wins over
    /// `foregroundProcessName` in `displayTitle`. The escape sequence itself
    /// carries no provenance — a shell that titles from its prompt (nushell,
    /// Starship, ghostty shell-integration — emitting `~/dir`, `host:~/dir`)
    /// is indistinguishable from a program naming its session — so
    /// `receiveReportedTitle` recovers provenance from the process table:
    /// a title is adopted only while the foreground process is NOT a shell,
    /// and it's pinned to that pid — `applyForegroundRefresh` expires it the
    /// moment a different process (usually the shell, on exit) takes the
    /// foreground, so an idle pane falls back to the process name.
    private(set) var programTitle: String?

    /// The foreground pid that set `programTitle`, used to expire it.
    @ObservationIgnored
    private var programTitlePID: pid_t?

    /// The AI coding agent in this pane's foreground (claude, codex, …), for
    /// the sidebar's agent logo. Derived in `applyForegroundRefresh` from the
    /// foreground process's `comm`/argv[0] and cached against the pid, so the
    /// poll's steady ticks don't re-read argv or churn `@Observable`.
    private(set) var agentIcon: AgentIcon?

    /// The foreground pid `agentIcon` was computed for.
    @ObservationIgnored
    private var agentIconPID: pid_t?

    let searchState = TerminalSearchState()
    var executionState: TerminalExecutionState = .idle {
        didSet {
            guard executionState != oldValue else { return }
            // A remote pane's OSC title expires when its command ends — the
            // execution edge is the pid-change analogue local panes get from
            // the poll (see `receiveRemoteReportedTitle`).
            if isRemote, oldValue == .running, programTitle != nil {
                programTitle = nil
            }
            // Transitions (idle→running, running→done) are exactly when the
            // adaptive poll should speed up; steady-state assignments and
            // per-frame heartbeats don't reach here (value unchanged).
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    @ObservationIgnored
    private var executionTracker = TerminalExecutionTracker()
    /// The global foreground poll pauses when the app has no visible window.
    /// Keep one lightweight wake scheduled from the final IO heartbeat so an
    /// occluded activity-owned run can still quiet-settle.
    @ObservationIgnored
    private var activityQuietPollTask: Task<Void, Never>?
    private let activityQuietPollDelay: Duration

    /// Re-read the foreground process name from the process table and publish it
    /// only when it changed (so a steady poll doesn't churn `@Observable` and
    /// re-render the sidebar every tick). Driven by `AppState`'s poll.
    ///
    /// `trackExecution` gates the expensive shell/raw-mode syscalls
    /// (`foregroundProcessIsShell` / `terminalInputIsRaw`) that only feed the
    /// status indicator. Callers on the hot poll pass a precomputed value so
    /// the pref is read once; the default reads `Preferences` for ad-hoc
    /// callers (OSC title, output/progress callbacks) so they stay gated too.
    func refreshForegroundProcess(trackExecution: Bool? = nil) {
        // Remote panes (#104): the local process table only knows the ssh
        // client — reading it would stomp the probe-derived name, expire
        // remote OSC titles, and feed the execution tracker a perpetual
        // "ssh is running". Names come from `RemoteForegroundResolver`,
        // titles from `receiveRemoteReportedTitle`, execution state from
        // OSC 133 markers and activity heartbeats.
        guard !isRemote else { return }
        let track = trackExecution ?? Preferences.shared.showTabStatusIndicator
        // Resolved ONCE and reused below, including inside the argv0 closure —
        // re-resolving there could disagree with this frame's pid on a wrapped
        // pane and would double the resolver work when the fallback fires.
        let resolvedPID = ProcessInspector.resolvedForegroundPID(forPane: self)
        applyForegroundRefresh(
            name: ProcessInspector.runningProcessName(forPane: self),
            // The RESOLVED foreground pid (daemon-side shell/program for a
            // wrapped pane), NOT the raw `nsView.foregroundPID` (the zmx attach
            // client). `programTitlePID` is pinned to this resolved pid, so the
            // expiry compare in `applyForegroundRefresh` must use the same
            // source — otherwise a wrapped pane's client pid never matches and
            // every adopted OSC title (e.g. Claude Code's "✳ Claude Code")
            // expires on the very next 250ms poll, snapping back to the process
            // name.
            foregroundPID: resolvedPID,
            foregroundIsShell: track ? ProcessInspector.foregroundProcessIsShell(forPane: self) : false,
            terminalInputIsRaw: track ? ProcessInspector.terminalInputIsRaw(forPane: self) : false,
            applyExecutionState: track,
            argv0: { resolvedPID.flatMap(ProcessInspector.invokedNameBasename(pid:)) }
        )
    }

    /// Testable core of `refreshForegroundProcess`: publish a changed process
    /// name, and expire `programTitle` when the pid that set it no longer
    /// holds the foreground. When `applyExecutionState` is false (the status
    /// indicator is off), the expensive execution-state path is skipped — only
    /// the process name / title provenance update runs.
    func applyForegroundRefresh(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool = false,
        terminalInputIsRaw: Bool = false,
        applyExecutionState: Bool = true,
        argv0: () -> String? = { nil }
    ) {
        let nameChanged = name != foregroundProcessName
        if nameChanged { foregroundProcessName = name }
        // A steady foreground (same pid, same comm) keeps the cached icon; a
        // change re-matches — argv[0] is only read when comm alone doesn't
        // identify an agent.
        if nameChanged || foregroundPID != agentIconPID {
            agentIconPID = foregroundPID
            let icon = foregroundPID == nil ? nil : AgentIcon.match(comm: name, argv0: argv0)
            if icon != agentIcon { agentIcon = icon }
        }
        if programTitle != nil, programTitlePID != foregroundPID {
            programTitle = nil
            programTitlePID = nil
        }
        guard applyExecutionState else { return }
        applyForegroundExecutionState(
            name: name,
            foregroundPID: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw
        )
    }

    func markCommandRunning() {
        executionState = executionTracker.markProgressStarted(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    func markCommandFinished() {
        executionState = executionTracker.markCommandFinished(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    func markProgressFinished() {
        executionState = executionTracker.markProgressFinished(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    func markTerminalActivity(at date: Date = Date()) {
        executionState = executionTracker.markTerminalActivity(
            at: date,
            currentState: executionState
        )
    }

    func settleTerminalActivityIfQuiet(now: Date = Date(), quietInterval: TimeInterval = 3) {
        executionState = executionTracker.settleIfQuiet(
            now: now,
            quietInterval: quietInterval,
            currentState: executionState
        )
        cancelActivityQuietPollIfNeeded()
    }

    func refreshTerminalActivityWindow(now: Date = Date()) {
        executionTracker.refreshActivityWindow(now: now)
    }

    /// Set on the first `OUTPUT_ACTIVITY` heartbeat delivered by libghostty
    /// for this surface. Its presence proves the running GhosttyKit build
    /// delivers occlusion-independent heartbeats (they fire from the pty IO
    /// path, not the renderer), so `AppState`'s quiet-settle no longer needs
    /// the occluded-pane exemption for this pane — silence while occluded is
    /// now a meaningful signal instead of an artifact of a parked renderer.
    private(set) var hasOcclusionIndependentHeartbeat = false

    /// Handle a throttled `OUTPUT_ACTIVITY` heartbeat (see
    /// `TerminalExecutionTracker.markOutputActivity`). Unlike
    /// `markTerminalActivity` (scrollbar-growth, visible surfaces only), this
    /// also reaches occluded/background panes.
    func markOutputActivity(totalRows: UInt64, now: Date = Date()) {
        hasOcclusionIndependentHeartbeat = true
        executionState = executionTracker.markOutputActivity(totalRows: totalRows, at: now, currentState: executionState)
        scheduleActivityQuietPollIfNeeded()
    }

    private func scheduleActivityQuietPollIfNeeded() {
        guard executionTracker.isActivitySourced else {
            cancelActivityQuietPollIfNeeded()
            return
        }
        activityQuietPollTask?.cancel()
        let delay = activityQuietPollDelay
        activityQuietPollTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            activityQuietPollTask = nil
            // This dedicated deadline bypasses ordinary event coalescing: if
            // every window is occluded there may be no timer left to retry.
            // AppState still performs the settle so acknowledgement and
            // persistence stay central.
            NotificationCenter.default.post(name: .terminalQuietSettleDeadline, object: self)
        }
    }

    private func cancelActivityQuietPollIfNeeded() {
        guard !executionTracker.isActivitySourced else { return }
        activityQuietPollTask?.cancel()
        activityQuietPollTask = nil
    }

    @discardableResult
    func acknowledgeCommandCompletion() -> Bool {
        guard executionState == .done else { return false }
        executionState = .idle
        return true
    }

    /// Restore the persisted "done / needs attention" state after a relaunch.
    /// Only the user-visible checkmark is restored; the live tracker starts
    /// idle, so the first real foreground/output signal behaves normally and
    /// a user interaction (or focusing the tab) clears it via
    /// `acknowledgeCommandCompletion`.
    func restoreNeedsAttention() {
        executionState = .done
    }

    func recordUserInteraction() {
        executionTracker.recordUserInteraction()
        acknowledgeCommandCompletion()
        // Keystrokes are the strongest "about to launch something" signal —
        // and the only one available while the non-activating quick terminal
        // has keyboard focus without app focus.
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    func recordCommandSubmission(hasContent: Bool, at date: Date = Date()) {
        // Plain Return is ambiguous in editors and menus. Only a nonempty
        // submission in a recognized AI agent gets the two-heartbeat in-place
        // start heuristic; ordinary programs still use process/row evidence.
        let allowInPlaceOutputStart = agentIcon != nil
            || AgentIcon.match(processName: foregroundProcessName) != nil
        executionTracker.recordCommandSubmission(
            at: date,
            allowInPlaceOutputStart: allowInPlaceOutputStart,
            hasContent: hasContent
        )
        acknowledgeCommandCompletion()
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    private func applyForegroundExecutionState(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool,
        terminalInputIsRaw: Bool
    ) {
        executionState = executionTracker.refreshForeground(
            name: name,
            pid: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw,
            currentState: executionState
        )
        cancelActivityQuietPollIfNeeded()
    }

    /// Handle an OSC 0/2 title reported by the surface. Always refreshes the
    /// foreground process (a title arrival is a command boundary); adopts the
    /// string as `programTitle` only when a real program — not the shell — is
    /// in the foreground (see `programTitle` for why).
    func receiveReportedTitle(_ title: String) {
        if isRemote {
            receiveRemoteReportedTitle(title)
            return
        }
        receiveReportedTitle(title, programPID: ProcessInspector.foregroundProgramPID(forPane: self))
    }

    /// Remote-pane title path (#104): there is no local foreground pid to
    /// gate provenance on (the local process is always `ssh`), so the OSC 133
    /// execution state stands in — a title arriving while a command runs is
    /// the program naming itself; one arriving at the prompt is shell churn,
    /// discarded exactly like the local gate discards it. Expiry is the
    /// running→ended edge in `executionState.didSet`.
    func receiveRemoteReportedTitle(_ title: String) {
        // A title arrival is a command boundary — wake the poll (it drives
        // the remote foreground probe). Deferred for the same render-loop
        // reason as the local path.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
        guard executionState == .running else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Discard a bare version number (see the local path) — e.g. remote
        // Claude Code emitting `2.1.202` as its title.
        guard !ProcessInspector.looksLikeVersionString(trimmed) else { return }
        if trimmed != programTitle { programTitle = trimmed }
        programTitlePID = nil
    }

    /// Tier-2 naming input for remote panes (#104): the remote resolver's
    /// foreground `comm` for this pane's session. A macOS remote reports
    /// `comm` as a full executable path — keep the basename, matching local
    /// kernel-comm behavior. nil (session missing from a successful probe)
    /// keeps the last-known name: a blip must not flap tab titles.
    func applyRemoteForegroundName(_ comm: String?) {
        guard let comm, !comm.isEmpty else { return }
        let base = Self.normalizeRemoteComm(comm)
        if !base.isEmpty, base != foregroundProcessName { foregroundProcessName = base }
    }

    /// Basename of a remote `ps -o comm=` value, minus the leading `-` a
    /// login shell carries in its argv[0] (`-/opt/homebrew/bin/nu` → `nu`,
    /// `-zsh` → `zsh`). Local kernel `comm` never has this dash, so the
    /// stripping is remote-only. Pure + static for testing.
    static func normalizeRemoteComm(_ comm: String) -> String {
        let stripped = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
        return (stripped as NSString).lastPathComponent
    }

    /// Testable core of `receiveReportedTitle`. `programPID` is the pane's
    /// foreground pid when that process is a non-shell program, nil otherwise.
    func receiveReportedTitle(_ title: String, programPID: pid_t?) {
        // A title arrival is a command boundary — wake the adaptive poll so
        // the other panes' names catch up too. Deferred: this path also runs
        // from the `onTitleChange` replay inside `TerminalSurface.configure`,
        // i.e. mid view-update — posting (and polling) synchronously there
        // re-invalidates SwiftUI from within its own render transaction.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
        refreshForegroundProcess()
        guard let programPID else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare version number is not a useful display title — Claude Code
        // emits its version (`2.1.202`) as an OSC 2 title at its prompt. Discard
        // it so `displayTitle` falls back to the process name instead of pinning
        // the version. (Its real status titles aren't version-shaped, so they
        // still adopt normally.)
        guard !ProcessInspector.looksLikeVersionString(trimmed) else { return }
        if trimmed != programTitle { programTitle = trimmed }
        programTitlePID = programPID
    }

    /// The live terminal NSView for this pane. Created lazily the first time
    /// it's requested, destroyed explicitly when the pane is removed from the
    /// tree. Owning the view on the model (instead of in a separate cache or
    /// inside SwiftUI) keeps the underlying ghostty surface alive across any
    /// SwiftUI view churn: tab switches, split tree reshapes, window hide/show.
    /// Not observed — SwiftUI should never re-render just because this changes.
    @ObservationIgnored
    private var _nsView: GhosttyTerminalNSView?

    func ensureNSView() -> GhosttyTerminalNSView {
        if let existing = _nsView { return existing }
        // Every pane's shell learns its own restart-stable address so
        // `macterm` invoked inside it can self-target (`MACTERM_SESSION`).
        // Injected at spawn, which means a zmx-reattached shell keeps the
        // value from its original spawn — correct, because the session name
        // is persisted verbatim and survives restarts (pane UUIDs don't).
        // Our value wins over a layout-declared duplicate: this is identity,
        // not configuration.
        var mergedEnv = env ?? [:]
        mergedEnv[ControlProtocol.sessionEnvVar] = sessionName
        let view = GhosttyTerminalNSView(
            workingDirectory: projectPath,
            sessionName: sessionName,
            command: command,
            shell: shell,
            env: mergedEnv,
            remoteSpec: remoteSpec,
            remoteZmxPath: remoteZmxPath
        )
        _nsView = view
        return view
    }

    var nsView: GhosttyTerminalNSView? { _nsView }

    /// The `NSScrollView` that hosts this pane's surface and renders the native
    /// overlay scrollbar. Owned here (not by SwiftUI) for the same reason as
    /// `_nsView`: it must survive tab switches and split reshapes, and it
    /// sidesteps Ghostty's #9444 bug where the scroll wrapper isn't persisted.
    @ObservationIgnored
    private var _scrollView: SurfaceScrollView?

    func ensureScrollView() -> SurfaceScrollView {
        if let existing = _scrollView { return existing }
        let scroll = SurfaceScrollView(surfaceView: ensureNSView())
        _scrollView = scroll
        return scroll
    }

    var scrollView: SurfaceScrollView? { _scrollView }

    /// Tear down the ghostty surface and null out callbacks. Call when the
    /// pane is removed from the tree. Safe to call multiple times.
    func destroySurface() {
        guard let view = _nsView else { return }
        // Null callbacks before destroy so any in-flight ghostty events
        // triggered by destroySurface() itself can't re-enter.
        view.onProcessExit = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        view.onFocus = nil
        view.onInteraction = nil
        view.onCommandSubmitted = nil
        view.onSplitRequest = nil
        view.onDesktopNotification = nil
        view.onCommandFinished = nil
        view.onProgressStarted = nil
        view.onProgressFinished = nil
        view.onTerminalActivity = nil
        view.onOutputActivity = nil
        view.onScrollbarUpdate = nil
        view.onScrollWheel = nil
        view.destroySurface()
        let scroll = _scrollView
        _scrollView = nil
        _nsView = nil
        // Keep the NSView (and its scroll-view host) alive for a runloop tick so
        // any in-flight ghostty callback (which holds an unretained pointer to
        // the view) can drain before the view is deallocated. Without this,
        // SwiftUI can remove the view from its superview the same turn we
        // destroy the surface, deallocating the NSView before ghostty has
        // finished unwinding.
        DispatchQueue.main.async {
            _ = view
            // Detach the scroll view from whatever still hosts it — notably the
            // SurfaceIncubator's hidden window, which never removes warmed
            // views itself — so the dead view pair can actually deallocate.
            scroll?.removeFromSuperview()
        }
    }

    var processTitle: String {
        // The live foreground process name (`hx`, `btop`) when a program is
        // running, else the shell name when idle. Always process-table derived
        // (never the OSC title) — the quit confirmation lists real process
        // names, and `displayTitle` falls back here. For a remote pane the
        // name comes from the remote probe; before one lands (or when the
        // host is unreachable) the host name is the honest fallback — the
        // local login shell never runs in a remote pane.
        if let proc = foregroundProcessName, !proc.isEmpty { return proc }
        if let remoteHost { return remoteHost }
        return Self.defaultShellName
    }

    /// What the tab/sidebar shows for this pane: a program-reported OSC title
    /// when one is live (see `programTitle`), else the process name.
    var displayTitle: String {
        if let title = programTitle, !title.isEmpty { return title }
        return processTitle
    }

    /// Display fallback for a pane with no foreground process yet (its surface
    /// hasn't been created) — the name of the login shell it will run. Resolves
    /// from the password database (`getpwuid`), the same shell libghostty
    /// launches when no explicit `command` is set. We avoid `$SHELL`: that's the
    /// shell of whatever launched the app (often `/bin/zsh`), not the user's
    /// login shell, so a `nu` user would otherwise see "zsh". Once the surface
    /// is live, `foregroundProcessName` (the actual `comm`) takes over.
    private static let defaultShellName: String = {
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }()

    var sidebarSegmentTitle: String {
        displayTitle
    }

    init(
        projectPath: String,
        projectID: UUID,
        sessionID: UUID = UUID(),
        sessionSlug: String? = nil,
        sessionName persistedSessionName: String? = nil,
        command: String? = nil,
        shell: String? = nil,
        env: [String: String]? = nil,
        activityQuietPollDelay: Duration = .seconds(3)
    ) {
        self.projectPath = projectPath
        self.projectID = projectID
        self.sessionID = sessionID
        if case let .remote(_, host, _)? = ProjectPath.parse(projectPath) {
            isRemote = true
            remoteHost = host
            remoteSpec = ProjectPath.remote(from: projectPath)
        } else {
            isRemote = false
            remoteHost = nil
            remoteSpec = nil
        }
        if let persistedSessionName {
            // Restore path: the snapshot's name is authoritative and used
            // VERBATIM — the slug inside it reflects the project at creation,
            // and re-deriving after a project rename would target a session
            // that doesn't exist. The slug is recovered only so a split off
            // this pane groups with it.
            sessionName = persistedSessionName
            self.sessionSlug = ZmxSessionName.slug(fromName: persistedSessionName)
                ?? (projectPath as NSString).lastPathComponent
        } else {
            let slug = sessionSlug ?? (projectPath as NSString).lastPathComponent
            self.sessionSlug = slug
            sessionName = ZmxSessionName.make(projectName: slug, paneSessionID: sessionID)
        }
        self.command = command
        self.shell = shell
        self.env = env
        self.activityQuietPollDelay = activityQuietPollDelay
        executionTracker = TerminalExecutionTracker(hasUserInteraction: command != nil)
    }

    /// Re-point this pane at a new workspace after its tab is moved between
    /// projects (`AppState.moveTab`). Updates ONLY the routing identity — the
    /// `projectID` that notification navigation and the quit sweep key on — so a
    /// notification click after a move finds the tab in its new project.
    ///
    /// Session identity (`sessionName`, `sessionSlug`, `projectPath`,
    /// `remoteSpec`, `remoteZmxPath`) is deliberately NOT touched: the shell
    /// keeps running on its original host under its original name, so a
    /// remote pane moved into a local project still tears down over ssh.
    func rebind(projectID: UUID) {
        self.projectID = projectID
    }

    /// Permanently kill this pane's zmx session. Call ONLY when the pane is
    /// gone for good (closed, tab/project removed, dropped by a layout apply)
    /// — NOT on transient teardown (window hide, tab-switch churn), where the
    /// daemon must survive. Fire-and-forget: close paths aren't blocked on it
    /// and ZmxClient's subprocess timeout bounds a stuck daemon. The client is
    /// a parameter so AppState's injectable instance flows through in tests.
    func killPersistentSession(using zmx: ZmxClient) {
        let name = sessionName
        if let remote = remoteSpec {
            let zmxPath = remoteZmxPath
            Task {
                await zmx.killRemoteSession(remote, name, zmxPath)
                // Post AFTER the kill so observers that re-list sessions see
                // the post-kill state instead of racing the still-alive one.
                NotificationCenter.default.post(name: .zmxSessionsChanged, object: nil)
            }
            return
        }
        Task {
            await zmx.killSession(name)
            NotificationCenter.default.post(name: .zmxSessionsChanged, object: nil)
        }
    }
}

/// Recursive split tree. Each leaf is a `Pane`, each branch splits two subtrees.
enum SplitNode: Identifiable {
    case pane(Pane)
    indirect case split(SplitBranch)

    var id: UUID {
        switch self {
        case let .pane(p): p.id
        case let .split(b): b.id
        }
    }
}

@MainActor @Observable
final class SplitBranch: Identifiable {
    let id = UUID()
    var direction: SplitDirection
    var ratio: CGFloat
    var first: SplitNode
    var second: SplitNode

    init(direction: SplitDirection, ratio: CGFloat = 0.5, first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// MARK: - Tree operations

@MainActor
extension SplitNode {
    func splitting(
        paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition,
        projectPath: String,
        projectID: UUID,
        command: String? = nil
    ) -> (node: SplitNode, newPaneID: UUID?) {
        switch self {
        case let .pane(p) where p.id == paneID:
            // Inherit the source pane's session slug so the new sibling groups
            // under the same project in `zmx ls`.
            let newPane = Pane(
                projectPath: projectPath, projectID: projectID, sessionSlug: p.sessionSlug, command: command
            )
            let first: SplitNode = position == .first ? .pane(newPane) : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : .pane(newPane)
            return (.split(SplitBranch(direction: direction, first: first, second: second)), newPane.id)
        case .pane:
            return (self, nil)
        case let .split(branch):
            let (newFirst, id1) = branch.first.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID,
                command: command
            )
            branch.first = newFirst
            if id1 != nil { return (.split(branch), id1) }
            let (newSecond, id2) = branch.second.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID,
                command: command
            )
            branch.second = newSecond
            return (.split(branch), id2)
        }
    }

    /// Insert an existing pane next to the pane `destinationID`, wrapping the
    /// destination in a new split with `pane` at `position`. The structural
    /// counterpart of `splitting`, used to re-attach a pane during a
    /// drag-and-drop move. Returns `inserted: false` (tree unchanged) when the
    /// destination isn't in the tree.
    func inserting(
        pane: Pane,
        at destinationID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (node: SplitNode, inserted: Bool) {
        switch self {
        case let .pane(p) where p.id == destinationID:
            let first: SplitNode = position == .first ? .pane(pane) : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : .pane(pane)
            return (.split(SplitBranch(direction: direction, first: first, second: second)), true)
        case .pane:
            return (self, false)
        case let .split(branch):
            let (newFirst, ok1) = branch.first.inserting(
                pane: pane, at: destinationID, direction: direction, position: position
            )
            branch.first = newFirst
            if ok1 { return (.split(branch), true) }
            let (newSecond, ok2) = branch.second.inserting(
                pane: pane, at: destinationID, direction: direction, position: position
            )
            branch.second = newSecond
            return (.split(branch), ok2)
        }
    }

    func removing(paneID: UUID) -> SplitNode? {
        switch self {
        case let .pane(p) where p.id == paneID: return nil
        case .pane: return self
        case let .split(branch):
            if case let .pane(p) = branch.first, p.id == paneID { return branch.second }
            if case let .pane(p) = branch.second, p.id == paneID { return branch.first }
            if branch.first.contains(paneID: paneID), let n = branch.first.removing(paneID: paneID) {
                branch.first = n
                return .split(branch)
            }
            if branch.second.contains(paneID: paneID), let n = branch.second.removing(paneID: paneID) {
                branch.second = n
                return .split(branch)
            }
            return self
        }
    }

    func contains(paneID: UUID) -> Bool {
        switch self {
        case let .pane(p): p.id == paneID
        case let .split(b): b.first.contains(paneID: paneID) || b.second.contains(paneID: paneID)
        }
    }

    func allPanes() -> [Pane] {
        switch self {
        case let .pane(p): [p]
        case let .split(b): b.first.allPanes() + b.second.allPanes()
        }
    }

    func findPane(id: UUID) -> Pane? {
        switch self {
        case let .pane(p): p.id == id ? p : nil
        case let .split(b): b.first.findPane(id: id) ?? b.second.findPane(id: id)
        }
    }

    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case let .pane(p):
            return [p.id: rect]
        case let .split(b):
            let r = min(max(b.ratio, 0), 1)
            if b.direction == .horizontal {
                let w1 = rect.width * r
                let r1 = CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
                let r2 = CGRect(x: rect.minX + w1, y: rect.minY, width: rect.width - w1, height: rect.height)
                return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
            }
            let h1 = rect.height * r
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            let r2 = CGRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: rect.height - h1)
            return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
        }
    }

    /// Find the nearest pane in a direction from the currently focused pane.
    func nearestPane(from focusedID: UUID, direction: PaneFocusDirection) -> UUID? {
        let frames = paneFrames()
        guard let focusedFrame = frames[focusedID] else { return nil }
        var bestID: UUID?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (id, frame) in frames where id != focusedID {
            let isCandidate: Bool = switch direction {
            case .left: frame.midX < focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .right: frame.midX > focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .up: frame.midY < focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            case .down: frame.midY > focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            }
            guard isCandidate else { continue }
            let dist: CGFloat = switch direction {
            case .left,
                 .right: abs(focusedFrame.midX - frame.midX)
            case .up,
                 .down: abs(focusedFrame.midY - frame.midY)
            }
            if dist < bestDist { bestDist = dist
                bestID = id
            }
        }
        return bestID
    }
}

enum PaneFocusDirection { case left, right, up, down }

@MainActor
extension SplitNode {
    /// Rebalance all ratios so sibling panes along each direction share space
    /// evenly. Mutates in place; returns the receiver for chaining.
    @discardableResult
    func rebalanced() -> SplitNode {
        if case let .split(branch) = self {
            let leftUnits = branch.first.tileUnits(along: branch.direction)
            let rightUnits = branch.second.tileUnits(along: branch.direction)
            let total = leftUnits + rightUnits
            if total > 0 {
                branch.ratio = CGFloat(leftUnits) / CGFloat(total)
            }
            _ = branch.first.rebalanced()
            _ = branch.second.rebalanced()
        }
        return self
    }

    /// Number of "cells" this subtree contributes when laid out along the given
    /// direction. Same-direction descendants expand to their leaf count;
    /// different-direction or leaf nodes count as a single cell.
    private func tileUnits(along direction: SplitDirection) -> Int {
        switch self {
        case .pane: 1
        case let .split(b):
            b.direction == direction
                ? b.first.tileUnits(along: direction) + b.second.tileUnits(along: direction)
                : 1
        }
    }

    /// Adjust the ratio of the nearest ancestor split in the given direction by `delta`.
    /// Returns the receiver if no matching split is found.
    func resizing(paneID: UUID, direction: PaneFocusDirection, delta: CGFloat) -> SplitNode {
        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        let sign: CGFloat = (direction == .right || direction == .down) ? 1 : -1
        _ = applyResize(paneID: paneID, axis: axis, delta: sign * delta)
        return self
    }

    /// Walks the tree and applies the delta to the closest matching-axis ancestor
    /// of the given pane. Returns true if the ratio was actually adjusted.
    @discardableResult
    private func applyResize(paneID: UUID, axis: SplitDirection, delta: CGFloat) -> Bool {
        guard case let .split(branch) = self else { return false }
        let firstHas = branch.first.contains(paneID: paneID)
        let secondHas = branch.second.contains(paneID: paneID)
        guard firstHas || secondHas else { return false }
        // Recurse first — deeper (closer) ancestor wins.
        let child: SplitNode = firstHas ? branch.first : branch.second
        if child.applyResize(paneID: paneID, axis: axis, delta: delta) { return true }
        // No deeper match; if this branch matches the axis, apply here.
        if branch.direction == axis {
            branch.ratio = min(max(branch.ratio + delta, 0.15), 0.85)
            return true
        }
        return false
    }

    /// Set the ratio of the nearest ancestor branch of `paneID` whose direction
    /// matches `axis` to an absolute value (clamped to 0.15…0.85). The control
    /// CLI's `pane resize-split` uses this for a deterministic geometry, in
    /// contrast to `applyResize`'s relative nudge (the keybind path). Returns
    /// true iff a matching branch was found and set.
    @discardableResult
    func settingRatio(paneID: UUID, axis: SplitDirection, ratio: CGFloat) -> Bool {
        guard case let .split(branch) = self else { return false }
        let firstHas = branch.first.contains(paneID: paneID)
        let secondHas = branch.second.contains(paneID: paneID)
        guard firstHas || secondHas else { return false }
        // Deeper (closer) ancestor wins, matching applyResize.
        let child: SplitNode = firstHas ? branch.first : branch.second
        if child.settingRatio(paneID: paneID, axis: axis, ratio: ratio) { return true }
        if branch.direction == axis {
            branch.ratio = min(max(ratio, 0.15), 0.85)
            return true
        }
        return false
    }
}
