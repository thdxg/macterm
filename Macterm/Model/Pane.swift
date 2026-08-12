import CoreGraphics
import Foundation

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
    /// The latest observation of this pane's foreground — name, shell-ness,
    /// provenance, and when it was made (`ForegroundSample`). The single
    /// foreground truth for BOTH worlds: local samples come from the process
    /// table via `refreshForegroundProcess()`, remote ones from the host
    /// probe via `applyRemoteForegroundName`. nil = no observation has ever
    /// been made (pre-surface locally; probe never landed remotely) — a
    /// state the busy-close policy treats conservatively. Republished only
    /// when the observation changes, so a steady poll doesn't re-render the
    /// sidebar every tick.
    private(set) var foregroundSample: ForegroundSample?

    /// The basename of the pane's live foreground process — a running command
    /// (`hx`, `btop`), or the pane's shell when idle at a prompt (so a nested
    /// `zsh` launched inside `nu` shows `zsh`). This is the tab name's
    /// default source. Reads through `foregroundSample`; the setter is a
    /// seam for tests (and synthesizes a sample with origin matching the
    /// pane's world) — production sampling goes through
    /// `refreshForegroundProcess()` / `applyRemoteForegroundName`.
    var foregroundProcessName: String? {
        get { foregroundSample?.name }
        set {
            guard let newValue else {
                foregroundSample = nil
                return
            }
            foregroundSample = ForegroundSample(
                name: newValue,
                isIdleShell: ProcessInspector.isShellProcessName(newValue),
                origin: isRemote ? .remoteProbe : .processTable(pid: nil),
                sampledAt: Date()
            )
        }
    }

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
            // Any execution transition on a remote pane is also a naming
            // boundary (idle→running: a program took the foreground;
            // running→ended: the shell owns it again) — request an immediate
            // probe rather than waiting out the resolver's throttle.
            if isRemote { remoteProbeRequest.request() }
            // Transitions (idle→running, running→done) are exactly when the
            // adaptive poll should speed up; steady-state assignments and
            // per-frame heartbeats don't reach here (value unchanged).
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    /// The pending-probe request for this remote pane (see
    /// `RemoteProbeRequest`). Set when the pane crossed an execution boundary
    /// and its host should be probed immediately, bypassing
    /// `RemoteForegroundResolver`'s per-host throttle — the remote mirror of
    /// the #210 command-boundary refresh in
    /// `TerminalSurface.onCommandFinished`: local panes re-read the process
    /// table right there, but `refreshForegroundProcess()` no-ops for remote
    /// panes (the local table only knows the ssh client), so a finished
    /// program's name lingered until the next scheduled probe — or, with the
    /// poll slowed/paused, until the user interacted. The resolver consumes
    /// the request when its probe actually fires; while a probe is inflight
    /// the request survives, so it is retried on the next tick instead of
    /// dropped.
    @ObservationIgnored
    private var remoteProbeRequest = RemoteProbeRequest(primed: false)

    var remoteProbePending: Bool { remoteProbeRequest.isPending }

    /// Note an execution boundary reported outside the execution tracker —
    /// the unconditional OSC 133;D hook in `TerminalSurface`, which fires
    /// even with the status indicator off (when no `executionState` edge
    /// exists at all). Posts a poll event so a slowed or paused poll wakes
    /// to fire the probe now.
    func noteRemoteCommandBoundary() {
        guard isRemote else { return }
        remoteProbeRequest.request()
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    /// The resolver fired a probe covering this pane's host — the pending
    /// boundary request is answered.
    func consumeRemoteProbeRequest() {
        remoteProbeRequest.consume()
    }

    /// The resolver's probe succeeded but its listing had no entry for this
    /// pane's session (the registration race — see
    /// `RemoteProbeRequest.noteMiss`). Re-arm the request, bounded, so the
    /// retry rides the next poll tick from any project. Only for a pane that
    /// has never been named: a named pane's listing miss is a blip, and
    /// `applyRemoteForegroundName` already keeps the last-known name. NOT
    /// re-armed on probe failure (unreachable host) — retrying can't name a
    /// pane the host won't answer for.
    func noteRemoteProbeMiss() {
        guard isRemote, foregroundProcessName == nil else { return }
        remoteProbeRequest.noteMiss()
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
            if nameChanged {
                foregroundSample = ForegroundSample(
                    name: name,
                    isIdleShell: ProcessInspector.isShellProcessName(name),
                    origin: .processTable(pid: foregroundPID),
                    sampledAt: Date()
                )
            }
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

    /// Tier-2 naming input for remote panes (#104): the remote resolver's
    /// foreground observation for this pane's session. A macOS remote
    /// reports `comm` as a full executable path — keep the basename,
    /// matching local kernel-comm behavior.
    ///
    /// The idle verdict prefers the HOST's own reading (`observation.isIdle`
    /// — foreground pgid == session leader, computed where the processes
    /// live), falling back to the local shell database only when the probe
    /// couldn't compute one. The local database is wrong in both directions
    /// across hosts: a remote-only login shell it doesn't list would read
    /// busy at an idle prompt forever, and a NESTED shell running inside the
    /// session shell would read idle even though closing kills it — the
    /// host-side verdict matches libghostty's local surface semantics
    /// (a nested shell is a running child) instead.
    func applyRemoteForeground(_ observation: RemoteForegroundObservation) {
        let base = Self.normalizeRemoteComm(observation.comm)
        guard !base.isEmpty else { return }
        let isIdleShell = observation.isIdle ?? ProcessInspector.isShellProcessName(base)
        if base != foregroundProcessName || isIdleShell != foregroundSample?.isIdleShell {
            foregroundSample = ForegroundSample(
                name: base,
                isIdleShell: isIdleShell,
                origin: .remoteProbe,
                sampledAt: Date()
            )
        }
    }

    /// Name-only variant (no host idle verdict — falls back to the local
    /// shell database). Kept for tests and callers that predate the
    /// observation wire format. nil (session missing from a successful
    /// probe) keeps the last-known name: a blip must not flap tab titles.
    func applyRemoteForegroundName(_ comm: String?) {
        guard let comm, !comm.isEmpty else { return }
        applyRemoteForeground(RemoteForegroundObservation(comm: comm, isIdle: nil))
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
    /// The verdict itself is `ForegroundPolicy.needsConfirmClose` — a pure
    /// function over the pane's sample, so the local/remote asymmetry lives
    /// in exactly one tested place. This wrapper just feeds it the live
    /// surface signal.
    var needsConfirmClose: Bool {
        ForegroundPolicy.needsConfirmClose(
            sample: foregroundSample,
            executionState: executionState,
            isRemote: isRemote,
            hasSurface: nsView != nil,
            surfaceBusy: nsView?.needsConfirmQuit() == true
        )
    }

    /// The remote-side busy verdict alone (see
    /// `ForegroundPolicy.remoteNeedsConfirmClose`), nil when no probe result
    /// has ever arrived. Kept as a pane property so tests exercise the
    /// decision without a live NSView.
    var remoteNeedsConfirmClose: Bool? {
        ForegroundPolicy.remoteNeedsConfirmClose(
            sample: foregroundSample,
            executionState: executionState
        )
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
        // Prime the first probe for a remote pane. Scheduled probes cover only
        // the frontmost project, so without this a restored pane in a
        // background project is never probed: its name stays nil and
        // `needsConfirmClose` falls back to the surface's ssh-is-always-busy
        // reading — every plain-shell close warned until the project was
        // brought frontmost once. The primed request rides along with any
        // project's poll tick (and even an occluded window), exactly like a
        // command-boundary request.
        remoteProbeRequest = RemoteProbeRequest(primed: isRemote)
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
