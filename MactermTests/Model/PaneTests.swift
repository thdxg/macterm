import Foundation
@testable import Macterm
import Testing

@MainActor
struct PaneTests {
    private func shellName() -> String {
        // Mirror Pane.defaultShellName: the login shell from the password
        // database, not $SHELL (which is the app-launcher's shell).
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }

    @Test
    func processTitle_uses_foreground_process_when_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "btop"
        #expect(p.processTitle == "btop")
    }

    @Test
    func processTitle_defaults_to_shell_name_when_idle() {
        // No foreground process (idle at a prompt) → the shell name. The OSC
        // title is never consulted.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = nil
        #expect(p.processTitle == shellName())
    }

    @Test
    func processTitle_treats_empty_foreground_name_as_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = ""
        #expect(p.processTitle == shellName())
    }

    @Test
    func sidebarSegmentTitle_matches_processTitle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "nvim"
        #expect(p.sidebarSegmentTitle == p.processTitle)
    }

    @Test
    func executionState_defaults_to_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(p.executionState == .idle)
    }

    @Test
    func applyForegroundRefresh_skipsExecutionState_whenIndicatorDisabled() {
        // Mirrors `refreshForegroundProcess(trackExecution: false)`: a non-shell
        // foreground process updates the name but must not flip executionState
        // when the status indicator is off, so icon-mode users don't pay for
        // tracker mutations (or the shell/raw syscalls the caller skipped).
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(
            name: "sleep",
            foregroundPID: 42,
            foregroundIsShell: false,
            terminalInputIsRaw: false,
            applyExecutionState: false
        )
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .idle)
    }

    @Test
    func initialForegroundBeforeUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.markTerminalActivity()
        p.settleTerminalActivityIfQuiet(now: Date(timeIntervalSince1970: 3), quietInterval: 3)
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .idle)
    }

    @Test
    func progressBeforeUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func layoutCommand_tracksInitialForegroundBeforeUserInteraction() {
        let p = Pane(projectPath: "/", projectID: UUID(), command: "npm test")
        p.applyForegroundRefresh(name: "npm", foregroundPID: 42)
        #expect(p.executionState == .running)
    }

    @Test
    func executionState_marks_running_then_done_then_idle_on_acknowledge() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markCommandFinished()
        #expect(p.executionState == .done)
        p.acknowledgeCommandCompletion()
        #expect(p.executionState == .idle)
    }

    @Test
    func progressFinishedFromIdle_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markProgressFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func progressStartAndFinish_tracksRunningThenDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func progressRunning_isNotCompletedByForegroundOrOutputActivity() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))
        p.settleTerminalActivityIfQuiet(now: Date(timeIntervalSince1970: 200), quietInterval: 3)
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_settlesCurrentForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_settlesNextForegroundProcessWhenNoneWasCaptured() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_ignoresOutputFromSettledForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        p.markTerminalActivity()
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_allowsForegroundRestartAfterProcessChanges() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        p.applyForegroundRefresh(name: "node", foregroundPID: 43)
        #expect(p.executionState == .running)
    }

    @Test
    func commandFinishedFromIdle_staysIdle() {
        // Shell integration emits OSC 133;D on every precmd, including empty
        // commands (Enter, Ctrl-C, Ctrl-L on an idle prompt). A COMMAND_FINISHED
        // with no preceding running state must not flip the pane to `.done`, or
        // clearing an idle terminal would persist a spurious checkmark.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func commandFinishedFromRunning_marksDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        #expect(p.executionState == .running)
        p.markCommandFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func applyForegroundRefresh_marks_nonShell_process_as_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .running)
    }

    @Test
    func applyForegroundRefresh_marks_done_when_foreground_returns_to_shell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.foregroundProcessName == shellName())
        #expect(p.executionState == .done)
    }

    @Test
    func applyForegroundRefresh_marks_longLivedApps_as_running_without_exclusions_when_terminalIsCanonical() {
        for process in ["claude", "pi", "node", "ssh"] {
            let p = Pane(projectPath: "/", projectID: UUID())
            p.recordUserInteraction()
            p.applyForegroundRefresh(name: process, foregroundPID: 42)
            #expect(p.foregroundProcessName == process)
            #expect(p.executionState == .running)
        }
    }

    @Test
    func rawForegroundProcess_doesNotStartFromForegroundAlone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "node", foregroundPID: 42, terminalInputIsRaw: true)
        #expect(p.foregroundProcessName == "node")
        #expect(p.executionState == .idle)
    }

    @Test
    func rawForegroundProcess_demotesExistingForegroundOnlyRun_thenSettlesWhenQuiet() {
        // A TUI that spawns canonical, prints, then goes raw (claude, pi) is
        // *starting* its work, not finishing — the raw switch demotes the
        // foreground-owned run to the activity source instead of completing
        // it outright, so it stays `.running` until output actually goes
        // quiet rather than locking the pane `.done` for the whole session.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .running)

        p.applyForegroundRefresh(name: "node", foregroundPID: 42, terminalInputIsRaw: true)
        #expect(p.executionState == .running)

        // No further output: the demoted run quiet-settles like any other
        // activity-sourced run.
        p.settleTerminalActivityIfQuiet(now: Date().addingTimeInterval(5), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func rawForegroundProcess_usesOutputActivityUntilQuiet() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42, terminalInputIsRaw: true)
        p.markTerminalActivity(at: start)
        #expect(p.executionState == .running)

        p.applyForegroundRefresh(name: "node", foregroundPID: 42, terminalInputIsRaw: true)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func terminalActivityWithoutUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markTerminalActivity()
        #expect(p.executionState == .idle)
    }

    @Test
    func terminalActivityAfterUserInteraction_marksRunningUntilQuiet() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.markTerminalActivity(at: start)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func commandSubmissionStartsOnSecondInPlaceOutputHeartbeatForAgent() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "pi"
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.recordCommandSubmission(hasContent: true, at: submittedAt)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(0.5))
        #expect(p.executionState == .idle)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(1))
        #expect(p.executionState == .running)
    }

    /// The view carries a programmatic payload's content evidence past the
    /// submission that consumed it only when this is true — otherwise a
    /// `pane run "…"` followed within the carry window by a genuinely blank
    /// Return would report content it doesn't have.
    @Test
    func inPlaceOutputStartIsAllowedOnlyForAnAgentForeground() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(!p.allowsInPlaceOutputStart)
        p.foregroundProcessName = "zsh"
        #expect(!p.allowsInPlaceOutputStart)
        p.foregroundProcessName = "pi"
        #expect(p.allowsInPlaceOutputStart)
    }

    @Test
    func commandSubmissionDoesNotArmInPlaceOutputForOrdinaryRawProgram() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "nvim"
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.recordCommandSubmission(hasContent: true, at: submittedAt)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(0.5))
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(1))
        #expect(p.executionState == .idle)
    }

    @Test
    func blankSubmissionSuppressesImmediateGrowthAndScrollbarActivity() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(-1))
        p.recordCommandSubmission(hasContent: false, at: submittedAt)

        p.markOutputActivity(totalRows: 20, now: submittedAt.addingTimeInterval(0.25))
        p.markTerminalActivity(at: submittedAt.addingTimeInterval(0.5))
        #expect(p.executionState == .idle)
    }

    @Test
    func outputActivitySchedulesQuietPollWake() async {
        let p = Pane(projectPath: "/", projectID: UUID(), activityQuietPollDelay: 0.02)
        p.recordUserInteraction()
        p.markOutputActivity(totalRows: 10)

        await confirmation("quiet output wakes the paused poll") { confirm in
            let fired = LockedBox(false)
            let token = NotificationCenter.default.addObserver(
                forName: .terminalQuietSettleDeadline,
                object: p,
                queue: .main
            ) { _ in
                fired.mutate { $0 = true }
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            p.markOutputActivity(totalRows: 20)
            // Poll rather than sleeping a fixed multiple of the delay: a
            // co-scheduled spike on a loaded CI runner can push a 20ms timer
            // well past any fixed margin (cf. #181). The generous ceiling only
            // bounds a genuine failure; a healthy run exits on the first tick.
            for _ in 0 ..< 200 where !fired.value {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// The scheduled wake must land strictly *after* the quiet threshold it
    /// needs to observe as crossed — a wake at exactly the threshold only
    /// settles while timer jitter runs positive, and an occluded window has no
    /// other timer left to retry with.
    @Test
    func quietPollWakeLandsAfterTheSettleThreshold() {
        #expect(TerminalActivityTiming.quietPollDelay > TerminalActivityTiming.quietInterval)
        #expect(
            TerminalActivityTiming.quietPollDelay
                == TerminalActivityTiming.quietInterval + TerminalActivityTiming.quietPollMargin
        )
    }

    @Test
    func foregroundProcessWithOutput_remainsRunningUntilItReturnsToShell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markTerminalActivity(at: start)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(30), quietInterval: 3)
        #expect(p.executionState == .running)

        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.executionState == .done)
    }

    @Test
    func silentForegroundProcess_doesNotSettleUntilItReturnsToShell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(30), quietInterval: 3)
        #expect(p.executionState == .running)
        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.executionState == .done)
    }

    @Test
    func init_stores_project_path() {
        let p = Pane(projectPath: "/tmp/foo", projectID: UUID())
        #expect(p.projectPath == "/tmp/foo")
    }

    @Test
    func destroySurface_is_safe_when_nsView_is_nil() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(p.nsView == nil)
        p.destroySurface() // must not crash
        p.destroySurface() // idempotent
        #expect(p.nsView == nil)
    }

    // MARK: - zmx session naming

    @Test
    func session_name_slugs_from_project_path_basename() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let p = Pane(projectPath: "/Users/me/dev/Macterm", projectID: UUID(), sessionID: id)
        #expect(p.sessionName == "macterm-macterm-aaaaaaaabbbb")
        #expect(p.sessionSlug == "Macterm")
    }

    @Test
    func explicit_session_slug_wins_over_path_basename() {
        let p = Pane(projectPath: NSHomeDirectory(), projectID: UUID(), sessionSlug: ZmxSessionName.quickTerminalSlug)
        #expect(p.sessionName.hasPrefix("macterm-quick-"))
    }

    @Test
    func split_inherits_the_source_panes_session_slug() throws {
        let source = Pane(projectPath: "/tmp", projectID: UUID(), sessionSlug: "myproj")
        let root = SplitNode.pane(source)
        let (newRoot, newID) = root.splitting(
            paneID: source.id, direction: .horizontal, position: .second,
            projectPath: "/somewhere/else", projectID: source.projectID
        )
        let createdID = try #require(newID)
        let newPane = try #require(newRoot.findPane(id: createdID))
        #expect(newPane.sessionSlug == "myproj")
        #expect(newPane.sessionName.hasPrefix("macterm-myproj-"))
        #expect(newPane.sessionName != source.sessionName)
    }

    // MARK: - Agent icon

    @Test
    func pane_caches_agent_across_steady_refreshes() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        var argvReads = 0
        let argv0: () -> String? = { argvReads += 1
            return "claude"
        }
        pane.applyForegroundRefresh(name: "2.1.207", foregroundPID: 42, argv0: argv0)
        #expect(pane.agentIcon == .claude)
        #expect(argvReads == 1)
        // Same pid + comm on the next tick: cached, argv untouched.
        pane.applyForegroundRefresh(name: "2.1.207", foregroundPID: 42, argv0: argv0)
        #expect(argvReads == 1)
        // Agent exits, shell takes the foreground.
        pane.applyForegroundRefresh(name: "zsh", foregroundPID: 7, argv0: { nil })
        #expect(pane.agentIcon == nil)
    }

    @Test
    func pane_has_no_agent_without_a_foreground_pid() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        pane.applyForegroundRefresh(name: nil, foregroundPID: nil, argv0: { "claude" })
        #expect(pane.agentIcon == nil)
    }

    // MARK: - Close confirmation (needsConfirmClose)

    @Test
    func needsConfirmClose_is_false_without_a_surface() {
        // No live NSView → nothing this session spawned can be running,
        // local or remote. (Remote leftovers from earlier state must not
        // stage a dialog for a pane that never came on screen.)
        let local = Pane(projectPath: "/", projectID: UUID())
        #expect(!local.needsConfirmClose)
        let remote = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        remote.executionState = .running
        remote.applyRemoteForegroundName("hx")
        #expect(!remote.needsConfirmClose)
    }

    @Test
    func remoteCloseVerdict_running_execution_state_is_busy() {
        // A command mid-output (OSC 133 / activity heartbeats) is busy even
        // before any probe result lands.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.executionState = .running
        #expect(p.remoteNeedsConfirmClose == true)
    }

    @Test
    func remoteCloseVerdict_shell_at_prompt_is_idle() {
        // The probe reporting the session's shell means an idle prompt — the
        // exact case that must NOT warn (an idle local pane doesn't). `-zsh`
        // is the login form the probe actually returns.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyRemoteForegroundName("-zsh")
        #expect(p.remoteNeedsConfirmClose == false)
        #expect(!p.needsConfirmClose)
    }

    @Test
    func remoteCloseVerdict_program_foreground_is_busy() {
        // A probe-named program is busy even when the execution tracker has
        // quiet-settled (a silent editor produces no heartbeats).
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyRemoteForegroundName("hx")
        #expect(p.executionState != .running)
        #expect(p.remoteNeedsConfirmClose == true)
    }

    @Test
    func remoteCloseVerdict_is_nil_before_any_probe_result() {
        // No probe has ever landed (unreachable host, BatchMode auth failure)
        // → no verdict; `needsConfirmClose` falls back to the conservative
        // surface reading rather than silently killing an unknown foreground.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        #expect(p.remoteNeedsConfirmClose == nil)
    }
}
