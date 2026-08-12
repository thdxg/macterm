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

/// Single source of truth for the two activity timings that must agree: how
/// long an activity-owned run may stay silent before it settles, and when the
/// dedicated wake that performs that settle fires. They are derived from one
/// constant so an edit can't drift them apart.
enum TerminalActivityTiming {
    /// Silence after which an activity-owned run settles to `.done`.
    static let quietInterval: TimeInterval = 3

    /// Slack added to `quietInterval` for the scheduled wake. The settle
    /// requires `now - lastActivityAt >= quietInterval`, so a wake targeting
    /// exactly the threshold only works while timer jitter runs positive — and
    /// the failure is bad: with every window occluded the ordinary poll is
    /// stopped, so a marginally early wake would no-op the settle with no timer
    /// left to retry, stranding the run at `.running` indefinitely. The margin
    /// makes the wake land strictly after the threshold instead.
    static let quietPollMargin: TimeInterval = 0.25

    /// Delay for the dedicated quiet-settle wake.
    static let quietPollDelay: TimeInterval = quietInterval + quietPollMargin
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
    /// Completion edges (OSC 133;D, the poll's return-to-shell) reset it to
    /// nil: the heartbeat throttle (500ms, leading-edge, drops — never defers)
    /// means a fast command's output often surfaces only on a LATER heartbeat,
    /// and growth measured across a completion must rebase rather than start a
    /// fresh activity run for a command that already ended.
    private var lastOutputRows: UInt64?
    /// A narrowly-armed path for work nested inside a recognized AI agent. The
    /// first in-place output heartbeat is only a candidate; a second within the
    /// submission window confirms sustained work.
    private var pendingOutputStart: PendingOutputStart?
    /// A forwarded Return with no committed prompt text can still make a TUI
    /// redraw or grow rows. Suppress those start signals briefly so an empty
    /// submission cannot flash the spinner.
    private var blankSubmissionAt: Date?
    /// True while the shell has reported a command finished (OSC 133;D) and has
    /// not been handed a new submission — i.e. it is sitting at a prompt.
    ///
    /// Returning to a prompt is not quiet: a hook-heavy shell forks a REAL
    /// external process per prompt (`starship prompt`, `mise hook-env`,
    /// `zoxide`), and the poll cannot tell one from a user command — same
    /// canonical tty, same non-shell foreground. Attributing one to the user is
    /// worse than a brief wrong glyph, because such a process is typically
    /// already dead when the poll spots it: nothing remains to observe a
    /// transition on, and a foreground-owned run has no self-settling wake of
    /// its own (unlike activity-owned runs). With the window occluded and the
    /// app inactive `PollCadence` returns `.paused` — no timer at all — so the
    /// phantom spinner stays up until something wakes the poll, which is why it
    /// looked like it "refreshed when I clicked on the app".
    ///
    /// Only foreground *starts* are gated. Output/progress evidence still
    /// applies, and a shell with no OSC 133 integration (bash 3.2) never sets
    /// this, so it keeps exactly today's foreground behavior.
    private var shellIsAtPrompt = false

    var isActivitySourced: Bool {
        if case .activity = runningSource { return true }
        return false
    }

    /// Whether the shell is sitting at a prompt — see `shellIsAtPrompt`. Read by
    /// the naming path so a prompt hook can't rename the tab.
    var isShellAtPrompt: Bool { shellIsAtPrompt }

    /// Record that the shell returned to a prompt, WITHOUT touching run state.
    /// The status-indicator pref gates `markCommandFinished`, but the naming
    /// path needs the prompt fact regardless of whether the spinner is shown.
    mutating func notePromptReturned() {
        shellIsAtPrompt = true
    }

    /// ORDERING CONTRACT: this CLEARS the in-place start arming, so a caller
    /// that reports both an interaction and a submission for the same event
    /// must call this FIRST — `recordCommandSubmission` arms, and an
    /// interaction recorded after it would silently disarm the Pi path. The
    /// `keyDown` / `sendText` / `sendKey` paths all fire `onInteraction` before
    /// `onCommandSubmitted` for exactly this reason.
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
        // The shell has been handed work, so a foreground process from here on
        // is that work rather than prompt-hook noise. A BLANK submission
        // deliberately does not clear this (it launches nothing), which is why
        // this sits after the `hasContent` guard.
        shellIsAtPrompt = false
        pendingOutputStart = allowInPlaceOutputStart ? .armed(date) : nil
    }

    mutating func markProgressStarted(currentState: TerminalExecutionState) -> TerminalExecutionState {
        pendingOutputStart = nil
        blankSubmissionAt = nil
        // A program reporting progress is positive evidence that work is
        // running, so the shell is no longer idling at a prompt.
        shellIsAtPrompt = false
        guard hasUserInteraction else { return currentState }
        runningSource = .progress
        return .running
    }

    mutating func markCommandFinished(currentState: TerminalExecutionState) -> TerminalExecutionState {
        // Shell integration (OSC 133;D) fires on every precmd, including an
        // empty Return. Always cancel its submission candidate, but only show a
        // completion when a command was genuinely running.
        pendingOutputStart = nil
        // Rebase row growth even when the completion lands while idle: a fast
        // command's output can be dropped by the heartbeat throttle, so the
        // next emitted heartbeat carries its growth AFTER this edge and must
        // not restart the finished command as an activity run.
        lastOutputRows = nil
        // D means the shell is back at a prompt, whatever the run state was.
        // Set unconditionally, ahead of the `.running` guard below: the prompt
        // hooks that follow a FAST command arrive on this path while the pane
        // still reads idle, and those are exactly the ones to suppress.
        shellIsAtPrompt = true
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
        // The row baseline rebases too: growth accumulated under the previous
        // foreground (possibly dropped by the heartbeat throttle) must not be
        // claimed as new activity after the transition — notably by the first
        // heartbeat after a command's process returned the foreground to the
        // shell.
        if changed {
            pendingOutputStart = nil
            blankSubmissionAt = nil
            lastOutputRows = nil
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
        // A process appearing while the shell sits at a prompt is a prompt hook,
        // not the user's command (see `shellIsAtPrompt`). Suppress the START
        // only — a run already owned by anything keeps its own rules.
        guard !shellIsAtPrompt else { return currentState }
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
    /// Temporary full-pane fill used when a TUI owns this leaf's background in
    /// a split. It is presentation-only, never persisted, and intentionally a
    /// CGColor so the model remains independent of AppKit and SwiftUI.
    var adaptiveBackgroundColor: CGColor?

    /// The OSC 8 link URL under the mouse, for the pane's hover banner
    /// (`GHOSTTY_ACTION_MOUSE_OVER_LINK`). Live UI state only — never
    /// persisted.
    var hoverURL: String?

    /// Bumped when the pane's scroll view finds itself orphaned with no
    /// living container to heal into (#227 — SwiftUI can deallocate a
    /// transient container outright, killing the weak re-attach pointer).
    /// `TerminalPane` reads this, so a bump re-renders the pane's subtree and
    /// `TerminalSurface.updateNSView` re-attaches on a container SwiftUI
    /// guarantees is alive. The owner-of-last-resort for view attachment.
    var surfaceReattachTick = 0

    func requestSurfaceReattach() {
        surfaceReattachTick &+= 1
    }

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
    private var activityQuietPollWork: DispatchWorkItem?
    private let activityQuietPollDelay: TimeInterval

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

    /// Whether a foreground sample must be ignored for this pane's IDENTITY
    /// (its name and agent icon).
    ///
    /// A hook-heavy shell forks a REAL process every time it draws a prompt —
    /// `starship prompt`, `mise hook-env`, `zoxide` — and each is briefly the
    /// pane's foreground. Publishing one renamed the tab to `starship`, and
    /// because the poll STOPS while the window is occluded and the app is
    /// inactive (`PollCadence.mode` → `.paused`), that wrong name then stuck
    /// until something re-sampled: clicking the app, or any keystroke.
    ///
    /// While the shell sits at a prompt nothing the user launched is running,
    /// so a non-shell foreground there can only be such a hook. A shell name
    /// (and `nil`) is always allowed through, so returning to the prompt
    /// restores the shell name at once. Shell-ness is decided by basename
    /// (`/etc/shells` + login shell + `$SHELL` — a set lookup, no syscall)
    /// rather than the caller's `foregroundIsShell`, which is only computed
    /// when the status-indicator pref turns the expensive path on.
    ///
    /// This gates the name and icon only. `programTitle` expiry stays keyed on
    /// the foreground pid, so a title can never be misattributed. A long-lived
    /// program (claude, hx) reports no completion while it runs, so the gate is
    /// never armed underneath it, and a shell with no OSC 133 integration never
    /// arms it at all — those panes keep exactly today's naming behavior.
    private func ignoresForegroundIdentity(_ name: String?) -> Bool {
        guard executionTracker.isShellAtPrompt, let name else { return false }
        return !ProcessInspector.isShellProcessName(name)
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
        // A prompt hook must not rename the tab. Title expiry below is NOT
        // gated: a changed pid means the title's owner lost the foreground, and
        // a title must never be misattributed to a different process.
        if !ignoresForegroundIdentity(name) {
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

    /// The shell returned to a prompt (OSC 133;D) — recorded even when the
    /// status indicator is off, because the naming path uses it to reject
    /// prompt-hook processes.
    func notePromptReturned() {
        executionTracker.notePromptReturned()
    }

    func markProgressFinished() {
        executionState = executionTracker.markProgressFinished(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    /// The row-growth activity primitive that `markOutputActivity` delegates
    /// to on a growing heartbeat. Exposed directly so tests can seed an
    /// activity-sourced run at a chosen instant without a growth baseline.
    func markTerminalActivity(at date: Date = Date()) {
        executionState = executionTracker.markTerminalActivity(
            at: date,
            currentState: executionState
        )
    }

    func settleTerminalActivityIfQuiet(
        now: Date = Date(),
        quietInterval: TimeInterval = TerminalActivityTiming.quietInterval
    ) {
        executionState = executionTracker.settleIfQuiet(
            now: now,
            quietInterval: quietInterval,
            currentState: executionState
        )
        cancelActivityQuietPollIfNeeded()
    }

    /// Handle a throttled `OUTPUT_ACTIVITY` heartbeat — the pane's sole source
    /// of terminal activity. It fires from the pty IO path (not the renderer),
    /// so unlike the scrollbar it also reaches occluded/background panes and
    /// its silence is always meaningful. `setup.sh` requires the GhosttyKit
    /// ABI that emits it, so the quiet-settle needs no occluded-pane exemption.
    /// Growth-vs-keepalive is decided in `TerminalExecutionTracker`.
    func markOutputActivity(totalRows: UInt64, now: Date = Date()) {
        executionState = executionTracker.markOutputActivity(totalRows: totalRows, at: now, currentState: executionState)
        scheduleActivityQuietPollIfNeeded()
    }

    private func scheduleActivityQuietPollIfNeeded() {
        guard executionTracker.isActivitySourced else {
            cancelActivityQuietPollIfNeeded()
            return
        }
        // Rescheduled on every heartbeat (~2 Hz per live pane), so this uses a
        // plain work item rather than spawning and cancelling a `Task` each
        // time — the same idiom the view's `commandSubmissionEvidenceReset`
        // uses.
        activityQuietPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            activityQuietPollWork = nil
            // This dedicated deadline bypasses ordinary event coalescing: if
            // every window is occluded there may be no timer left to retry.
            // AppState still performs the settle so acknowledgement and
            // persistence stay central.
            NotificationCenter.default.post(name: .terminalQuietSettleDeadline, object: self)
        }
        activityQuietPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activityQuietPollDelay, execute: work)
    }

    private func cancelActivityQuietPollIfNeeded() {
        guard !executionTracker.isActivitySourced else { return }
        activityQuietPollWork?.cancel()
        activityQuietPollWork = nil
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

    /// True when a recognized AI agent holds the foreground. Two things key off
    /// it: the two-heartbeat in-place start heuristic (below), and the view's
    /// decision to carry a programmatic payload's content evidence forward —
    /// both are only meaningful in a raw-mode agent TUI, where a bracketed
    /// paste can leave the payload sitting unsubmitted in the editor buffer.
    var allowsInPlaceOutputStart: Bool {
        agentIcon != nil || AgentIcon.match(processName: foregroundProcessName) != nil
    }

    func recordCommandSubmission(hasContent: Bool, at date: Date = Date()) {
        // Plain Return is ambiguous in editors and menus. Only a nonempty
        // submission in a recognized AI agent gets the two-heartbeat in-place
        // start heuristic; ordinary programs still use process/row evidence.
        let allowInPlaceOutputStart = allowsInPlaceOutputStart
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

    /// The full command line of the remote foreground process, from the probe
    /// (`ps -o args=`) — what Save Layout records as the pane's `run:` and the
    /// reconciler matches against, standing in for the local KERN_PROCARGS2
    /// argv (`ProcessInspector.runningCommand`). nil while the remote pane is
    /// idle at its shell prompt or before any probe result has landed — the
    /// same "idle saves no run" contract local panes get. Not observed: only
    /// the on-demand layout paths read it, and the ~3s probe re-applies it on
    /// every success.
    @ObservationIgnored
    private(set) var remoteForegroundCommand: String?

    /// Tier-2 naming input for remote panes (#104): the remote resolver's
    /// probed foreground for this pane's session. A macOS remote reports
    /// `comm` as a full executable path — keep the basename, matching local
    /// kernel-comm behavior. nil (session missing from a successful probe)
    /// keeps the last-known name and command: a blip must not flap tab titles.
    ///
    /// `remoteForegroundCommand` follows the local `runningCommand` contract:
    /// a shell at its prompt is idle (no command), anything else records the
    /// probe's full command line — falling back to the comm basename when the
    /// probe line carried no args field.
    func applyRemoteForeground(_ foreground: RemoteForeground?) {
        guard let foreground, !foreground.comm.isEmpty else { return }
        let base = Self.normalizeRemoteComm(foreground.comm)
        guard !base.isEmpty else { return }
        if base != foregroundProcessName { foregroundProcessName = base }
        remoteForegroundCommand = ProcessInspector.isShellProcessName(base)
            ? nil
            : (foreground.command ?? base)
    }

    /// Name-only convenience over `applyRemoteForeground` (no probed args).
    func applyRemoteForegroundName(_ comm: String?) {
        guard let comm else { return }
        applyRemoteForeground(RemoteForeground(comm: comm, command: nil))
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
            paneID: id,
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

    /// Whether closing this pane must be confirmed first because a foreground
    /// program is running. This is the single signal every busy-close guard
    /// reads (pane/tab close, project unload/remove, the CLI's `busy` error,
    /// the quit dialog rows).
    ///
    /// Local panes read libghostty's own signal (`needsConfirmQuit`). A remote
    /// pane can't: its local process is the `ssh` client, which libghostty
    /// counts as a running program forever — an idle remote prompt would
    /// always warn. Busyness is instead derived from the remote-side signals
    /// we do have (`remoteNeedsConfirmClose`); only when neither has produced
    /// a verdict yet does it fall back to the conservative surface reading.
    var needsConfirmClose: Bool {
        guard let view = nsView else { return false }
        guard isRemote else { return view.needsConfirmQuit() }
        return remoteNeedsConfirmClose ?? view.needsConfirmQuit()
    }

    /// The remote-side busy verdict: the OSC 133/heartbeat execution state
    /// (catches a command mid-output even before a probe lands), else the
    /// probe-derived foreground name — a shell at its prompt is idle, anything
    /// else is a running program. nil when no probe result has ever arrived
    /// (unreachable host, BatchMode auth failure, the first ~3s), so the
    /// caller can fall back rather than silently kill an unknown foreground.
    /// Split from `needsConfirmClose` so unit tests can exercise the decision
    /// without a live NSView.
    var remoteNeedsConfirmClose: Bool? {
        if executionState == .running { return true }
        guard let name = foregroundProcessName, !name.isEmpty else { return nil }
        return !ProcessInspector.isShellProcessName(name)
    }

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
        view.onTerminalRender = nil
        view.onBackgroundColorChange = nil
        view.onAdaptiveBackgroundChange = nil
        view.onOutputActivity = nil
        view.onScrollbarUpdate = nil
        view.onScrollWheel = nil
        view.onLinkHover = nil
        view.onMouseShapeChange = nil
        view.onPromptTitle = nil
        view.onSetTabTitle = nil
        view.titleProvider = nil
        // Release any secure-input scope this view holds (a pane closed
        // mid-password-prompt must not leave the OS state stuck on).
        view.passwordInput = false
        view.destroySurface()
        let scroll = _scrollView
        // Disarm the orphan-healing re-attach BEFORE the removal below —
        // otherwise a destroyed pane would climb back into its old container.
        scroll?.reattachHost = nil
        scroll?.onOrphaned = nil
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
        activityQuietPollDelay: TimeInterval = TerminalActivityTiming.quietPollDelay
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
        inserting(node: .pane(pane), at: destinationID, direction: direction, position: position)
    }

    /// Insert a whole subtree next to the pane `destinationID`, wrapping the
    /// destination in a new split with `node` at `position`. Generalizes the
    /// single-pane variant so a dragged tab's entire split tree can land beside
    /// a pane in one structural move (its panes and surfaces reused as-is).
    func inserting(
        node: SplitNode,
        at destinationID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (node: SplitNode, inserted: Bool) {
        switch self {
        case let .pane(p) where p.id == destinationID:
            let first: SplitNode = position == .first ? node : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : node
            return (.split(SplitBranch(direction: direction, first: first, second: second)), true)
        case .pane:
            return (self, false)
        case let .split(branch):
            let (newFirst, ok1) = branch.first.inserting(
                node: node, at: destinationID, direction: direction, position: position
            )
            branch.first = newFirst
            if ok1 { return (.split(branch), true) }
            let (newSecond, ok2) = branch.second.inserting(
                node: node, at: destinationID, direction: direction, position: position
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
    /// different-direction or leaf nodes count as a single cell. Also feeds
    /// `TabDropPlacer`'s preview widths (#227).
    func tileUnits(along direction: SplitDirection) -> Int {
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
