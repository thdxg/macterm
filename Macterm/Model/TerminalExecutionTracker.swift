import Foundation

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
