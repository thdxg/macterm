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
    func progressBeforeUserInteraction_tracksRunningThenDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
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
    func progressFinished_allowsNextForegroundProcessWhenNoneWasCaptured() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .running)
    }

    @Test
    func progressFinished_allowsOutputFromSettledForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        p.markTerminalActivity()
        #expect(p.executionState == .running)
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
    func rawForegroundProcess_settlesExistingForegroundOnlyRun() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .running)

        p.applyForegroundRefresh(name: "node", foregroundPID: 42, terminalInputIsRaw: true)
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
    func rawForegroundProcess_renderOnlyRefreshStartsSpinner() {
        // Alternate-screen TUIs such as btop/htop/vim can repaint continuously
        // without increasing scrollback. That arrives as the render callback path,
        // so a render-only foreground refresh must be enough to show activity.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "btop", foregroundPID: 42, terminalInputIsRaw: true)

        simulateTerminalRender(
            for: p,
            name: "btop",
            foregroundPID: 42,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(p.executionState == .running)
    }

    @Test
    func layoutRawCommand_renderOnlyRefreshStartsSpinner() {
        // Declarative `run:` panes seed interaction because the app injected the
        // command. A layout that starts an alternate-screen program still misses
        // the spinner when the program only repaints.
        let p = Pane(projectPath: "/", projectID: UUID(), command: "btop")
        p.applyForegroundRefresh(name: "btop", foregroundPID: 42, terminalInputIsRaw: true)

        simulateTerminalRender(
            for: p,
            name: "btop",
            foregroundPID: 42,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(p.executionState == .running)
    }

    @Test
    func rawModeTransition_renderOnlyRefreshRestartsSpinner() {
        // Interactive CLIs often start in canonical mode, then switch the tty to
        // raw/cbreak once their UI is active. Repaints after that transition must
        // bring the spinner back.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "claude", foregroundPID: 42)
        p.applyForegroundRefresh(name: "claude", foregroundPID: 42, terminalInputIsRaw: true)
        #expect(p.executionState == .done)

        simulateTerminalRender(
            for: p,
            name: "claude",
            foregroundPID: 42,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(p.executionState == .running)
    }

    @Test
    func rawModeTransition_outputActivityRestartsSpinner() {
        // Same raw-mode transition, but with explicit output/scrollback activity
        // after the pane has already switched to `.done`.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "claude", foregroundPID: 42)
        p.applyForegroundRefresh(name: "claude", foregroundPID: 42, terminalInputIsRaw: true)
        #expect(p.executionState == .done)

        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))

        #expect(p.executionState == .running)
    }

    @Test
    func rawForegroundProcess_resumedOutputAfterQuietRestartsSpinner() {
        // A long-lived raw-mode program can go quiet for a few seconds and then
        // repaint/output again. New terminal activity from the same live program
        // should restart the spinner after the prior heartbeat settled to `.done`.
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "watch", foregroundPID: 42, terminalInputIsRaw: true)
        p.markTerminalActivity(at: start)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)

        p.markTerminalActivity(at: start.addingTimeInterval(10))

        #expect(p.executionState == .running)
    }

    @Test
    func newRawForegroundWhileDone_renderOnlyRefreshStartsSpinner() {
        // A stale done indicator should not hide a fresh raw-mode foreground
        // program. This simulates a pane with an uncleared completion badge, then
        // a new alternate-screen program repainting.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.executionState == .done)

        simulateTerminalRender(
            for: p,
            name: "btop",
            foregroundPID: 44,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(p.executionState == .running)
    }

    @Test
    func newRawForegroundWhileDone_outputActivityStartsSpinner() {
        // Same stale done state, but through the output activity callback rather
        // than the render callback. The new live foreground must override the
        // stale `.done` state.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.executionState == .done)

        p.applyForegroundRefresh(name: "watch", foregroundPID: 44, terminalInputIsRaw: true)
        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))

        #expect(p.executionState == .running)
    }

    @Test
    func progressReportBeforeLocalInteractionStartsSpinner() {
        // OSC progress is an explicit "this terminal is doing work" signal, even
        // if Macterm has not first recorded local key/mouse interaction.
        let p = Pane(projectPath: "/", projectID: UUID())

        p.markCommandRunning()

        #expect(p.executionState == .running)
    }

    @Test
    func progressReportAfterRestoredDoneStartsSpinner() {
        // Restoring a background completion badge should not block a later
        // explicit progress report from the terminal program.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.restoreNeedsAttention()

        p.markCommandRunning()

        #expect(p.executionState == .running)
    }

    @Test
    func progressReportWithForegroundBeforeLocalInteractionStartsSpinner() {
        // Even before local interaction has been recorded, a known foreground's
        // explicit progress signal should show activity.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "npm", foregroundPID: 42)

        p.markCommandRunning()

        #expect(p.executionState == .running)
    }

    @Test
    func progressFinishedForeground_outputActivityRestartsSpinner() {
        // Some tools clear OSC progress before post-processing or follow-up output
        // is actually finished. The same foreground process must be able to show
        // the spinner again when fresh activity arrives.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)

        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))

        #expect(p.executionState == .running)
    }

    @Test
    func progressFinishedForeground_renderOnlyRefreshRestartsSpinner() {
        // Same progress-quiesced foreground, but with a render-only refresh. This
        // models an in-place progress UI that repaints after clearing OSC progress.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)

        simulateTerminalRender(
            for: p,
            name: "node",
            foregroundPID: 42,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(p.executionState == .running)
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
    func foregroundProcessWithOutput_settlesAfterQuiet_withoutRestartingSameProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markTerminalActivity(at: start)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
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

    private func simulateTerminalRender(
        for pane: Pane,
        name: String,
        foregroundPID: pid_t,
        foregroundIsShell: Bool = false,
        terminalInputIsRaw: Bool = false,
        at date: Date
    ) {
        // Mirrors TerminalPane.onTerminalRender: refresh foreground context when
        // needed, then pass a weak render signal to the tracker.
        if pane.executionState != .running {
            pane.applyForegroundRefresh(
                name: name,
                foregroundPID: foregroundPID,
                foregroundIsShell: foregroundIsShell,
                terminalInputIsRaw: terminalInputIsRaw
            )
        }
        pane.markTerminalActivity(at: date, kind: .render)
    }
}
