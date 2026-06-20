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
    func executionState_marks_running_then_done_then_idle_on_acknowledge() {
        let p = Pane(projectPath: "/", projectID: UUID())
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
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func progressRunning_isNotCompletedByForegroundOrOutputActivity() {
        let p = Pane(projectPath: "/", projectID: UUID())
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
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_ignoresOutputFromSettledForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        p.markTerminalActivity()
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_allowsForegroundRestartAfterProcessChanges() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "node", foregroundPID: 42)
        p.markCommandRunning()
        p.markProgressFinished()
        p.applyForegroundRefresh(name: "node", foregroundPID: 43)
        #expect(p.executionState == .running)
    }

    @Test
    func commandFinishedFromIdle_marksDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func applyForegroundRefresh_marks_nonShell_process_as_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .running)
    }

    @Test
    func applyForegroundRefresh_marks_done_when_foreground_returns_to_shell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.applyForegroundRefresh(name: "sleep", foregroundPID: 42)
        p.applyForegroundRefresh(name: shellName(), foregroundPID: 43, foregroundIsShell: true)
        #expect(p.foregroundProcessName == shellName())
        #expect(p.executionState == .done)
    }

    @Test
    func applyForegroundRefresh_marks_longLivedApps_as_running_without_exclusions_when_terminalIsCanonical() {
        for process in ["claude", "pi", "node", "ssh"] {
            let p = Pane(projectPath: "/", projectID: UUID())
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
}
