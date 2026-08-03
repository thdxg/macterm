import Foundation
@testable import Macterm
import Testing

/// Pins the source-precedence rules behind the tab activity indicator.
/// Foreground/progress are authoritative; output may start or sustain only
/// under the guarded interaction and submission rules exercised below.
struct TerminalExecutionTrackerTests {
    @Test
    func markTerminalActivity_fromIdleWithoutInteraction_staysIdle() {
        var tracker = TerminalExecutionTracker()
        let state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 1), currentState: .idle)
        #expect(state == .idle)
    }

    @Test
    func markTerminalActivity_fromIdleWithInteraction_startsRun() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 1), currentState: .idle)
        #expect(state == .running)
    }

    @Test
    func markTerminalActivity_fromDone_doesNotReturnToRunning() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 100), currentState: .idle)
        state = tracker.settleIfQuiet(now: Date(timeIntervalSince1970: 103), quietInterval: 3, currentState: state)
        state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 110), currentState: state)
        #expect(state == .done)
    }

    @Test
    func markTerminalActivity_fromRunning_keepsAliveAndRefreshesTimestamp() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markTerminalActivity(at: start, currentState: .idle)
        state = tracker.markTerminalActivity(at: start.addingTimeInterval(2), currentState: state)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(5), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func markOutputActivity_growthStartsOnlyAfterInteraction() {
        var tracker = TerminalExecutionTracker()
        var state = tracker.markOutputActivity(totalRows: 10, at: Date(timeIntervalSince1970: 1), currentState: .idle)
        state = tracker.markOutputActivity(totalRows: 20, at: Date(timeIntervalSince1970: 2), currentState: state)
        #expect(state == .idle)

        tracker.recordUserInteraction()
        state = tracker.markOutputActivity(totalRows: 30, at: Date(timeIntervalSince1970: 3), currentState: state)
        #expect(state == .running)
    }

    @Test
    func markOutputActivity_nonGrowthOnlySustainsActivityRun() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(totalRows: 10, at: start, currentState: .idle)
        state = tracker.markOutputActivity(totalRows: 10, at: start.addingTimeInterval(1), currentState: state)
        #expect(state == .idle)

        state = tracker.markTerminalActivity(at: start.addingTimeInterval(2), currentState: state)
        state = tracker.markOutputActivity(totalRows: 10, at: start.addingTimeInterval(4), currentState: state)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(6), quietInterval: 3, currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(7), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func markOutputActivity_growthDoesNotDemoteCanonicalForegroundRun() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "sleep", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: .idle
        )
        #expect(state == .running)

        state = tracker.markOutputActivity(totalRows: 10, at: Date(timeIntervalSince1970: 1), currentState: state)
        state = tracker.markOutputActivity(totalRows: 20, at: Date(timeIntervalSince1970: 2), currentState: state)
        state = tracker.settleIfQuiet(now: Date(timeIntervalSince1970: 30), quietInterval: 3, currentState: state)
        #expect(state == .running)

        state = tracker.refreshForeground(
            name: "zsh", pid: 43, foregroundIsShell: true, terminalInputIsRaw: false, currentState: state
        )
        #expect(state == .done)
    }

    @Test
    func markOutputActivity_doesNotResurrectDoneOrReplaceProgress() {
        var doneTracker = TerminalExecutionTracker()
        doneTracker.recordUserInteraction()
        var doneState = doneTracker.markTerminalActivity(at: Date(timeIntervalSince1970: 1), currentState: .idle)
        doneState = doneTracker.settleIfQuiet(
            now: Date(timeIntervalSince1970: 4), quietInterval: 3, currentState: doneState
        )
        _ = doneTracker.markOutputActivity(totalRows: 10, at: Date(timeIntervalSince1970: 5), currentState: doneState)
        doneState = doneTracker.markOutputActivity(
            totalRows: 20, at: Date(timeIntervalSince1970: 6), currentState: doneState
        )
        #expect(doneState == .done)

        var progressTracker = TerminalExecutionTracker()
        progressTracker.recordUserInteraction()
        var progressState = progressTracker.markProgressStarted(currentState: .idle)
        _ = progressTracker.markOutputActivity(
            totalRows: 10, at: Date(timeIntervalSince1970: 1), currentState: progressState
        )
        progressState = progressTracker.markOutputActivity(
            totalRows: 20, at: Date(timeIntervalSince1970: 2), currentState: progressState
        )
        progressState = progressTracker.settleIfQuiet(
            now: Date(timeIntervalSince1970: 100), quietInterval: 3, currentState: progressState
        )
        #expect(progressState == .running)
    }

    @Test
    func rawForegroundCannotStartButCanonicalRunDemotesAndSettles() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "pi", pid: 42, foregroundIsShell: false, terminalInputIsRaw: true, currentState: .idle
        )
        #expect(state == .idle)

        state = tracker.refreshForeground(
            name: "pi", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: state
        )
        #expect(state == .idle)
        state = tracker.refreshForeground(
            name: "pi", pid: 43, foregroundIsShell: false, terminalInputIsRaw: false, currentState: state
        )
        #expect(state == .running)

        let rawAt = Date(timeIntervalSince1970: 100)
        state = tracker.refreshForeground(
            name: "pi",
            pid: 43,
            foregroundIsShell: false,
            terminalInputIsRaw: true,
            at: rawAt,
            currentState: state
        )
        state = tracker.markOutputActivity(totalRows: 10, at: rawAt.addingTimeInterval(2), currentState: state)
        state = tracker.settleIfQuiet(now: rawAt.addingTimeInterval(4), quietInterval: 3, currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: rawAt.addingTimeInterval(5), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    /// The reported "spinner lingers ~3s after `ls`" sequence, replayed exactly.
    ///
    /// In a hook-heavy shell (starship / mise / zoxide), returning to the prompt
    /// briefly runs a real external process, which the poll can catch as a
    /// foreground command. What happens next depends entirely on whether the
    /// pane's own shell is recognized as a shell on the following poll — the
    /// single value `ProcessInspector.foregroundProcessIsShell` returns, which
    /// the `--execute` classification bug had stuck at `false` for every
    /// nushell pane (see `ProcessInspectorTests`).
    ///
    /// Misclassified, the return-to-prompt looks like "a non-shell program went
    /// raw", which demotes the run to activity ownership — exiting only through
    /// the 3-second quiet-settle. Classified correctly it is the authoritative
    /// completion edge and the run ends on the very next poll.
    @Test
    func promptHookRun_endsAtOncePerShellClassification_insteadOfQuietSettling() {
        let submittedAt = Date(timeIntervalSince1970: 100)

        func replay(shellIsRecognized: Bool) -> (
            afterPrompt: TerminalExecutionState,
            atTwoSeconds: TerminalExecutionState,
            atFourSeconds: TerminalExecutionState
        ) {
            var tracker = TerminalExecutionTracker()
            // Idle at the prompt: nushell holds the tty in raw mode for line editing.
            var state = tracker.refreshForeground(
                name: "nu", pid: 1, foregroundIsShell: shellIsRecognized, terminalInputIsRaw: true,
                at: submittedAt.addingTimeInterval(-1), currentState: .idle
            )
            tracker.recordUserInteraction()
            tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: false, hasContent: true)

            // `ls` is a nushell builtin — it never appears as a process. The
            // poll instead catches the pre-prompt hook, canonical and non-shell.
            state = tracker.refreshForeground(
                name: "starship", pid: 2, foregroundIsShell: false, terminalInputIsRaw: false,
                at: submittedAt.addingTimeInterval(0.25), currentState: state
            )
            #expect(state == .running)

            // Next poll: the prompt is back, raw mode again.
            let promptAt = submittedAt.addingTimeInterval(0.5)
            state = tracker.refreshForeground(
                name: "nu", pid: 1, foregroundIsShell: shellIsRecognized, terminalInputIsRaw: true,
                at: promptAt, currentState: state
            )
            let afterPrompt = state
            let atTwo = tracker.settleIfQuiet(
                now: promptAt.addingTimeInterval(2), quietInterval: 3, currentState: state
            )
            let atFour = tracker.settleIfQuiet(
                now: promptAt.addingTimeInterval(4), quietInterval: 3, currentState: atTwo
            )
            return (afterPrompt, atTwo, atFour)
        }

        // The bug: the run survives the prompt and only clears on quiet-settle.
        let buggy = replay(shellIsRecognized: false)
        #expect(buggy.afterPrompt == .running)
        #expect(buggy.atTwoSeconds == .running)
        #expect(buggy.atFourSeconds == .done)

        // Fixed: returning to the prompt IS the completion edge.
        let fixed = replay(shellIsRecognized: true)
        #expect(fixed.afterPrompt == .done)
    }

    @Test
    func samePIDReturningToCanonicalRestoresForegroundAuthority() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "agent", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: .idle
        )
        state = tracker.refreshForeground(
            name: "agent",
            pid: 42,
            foregroundIsShell: false,
            terminalInputIsRaw: true,
            at: Date(timeIntervalSince1970: 100),
            currentState: state
        )
        state = tracker.refreshForeground(
            name: "agent", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: state
        )
        state = tracker.settleIfQuiet(
            now: Date(timeIntervalSince1970: 1000), quietInterval: 3, currentState: state
        )
        #expect(state == .running)

        state = tracker.refreshForeground(
            name: "zsh", pid: 43, foregroundIsShell: true, terminalInputIsRaw: false, currentState: state
        )
        #expect(state == .done)
    }

    @Test
    func settledSamePIDRawProcessDoesNotRestartWhenCanonical() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "agent", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: .idle
        )
        let rawAt = Date(timeIntervalSince1970: 100)
        state = tracker.refreshForeground(
            name: "agent",
            pid: 42,
            foregroundIsShell: false,
            terminalInputIsRaw: true,
            at: rawAt,
            currentState: state
        )
        state = tracker.settleIfQuiet(now: rawAt.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .done)

        state = tracker.refreshForeground(
            name: "agent", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false, currentState: state
        )
        #expect(state == .done)
    }

    @Test
    func submittedCommand_requiresTwoNonGrowingHeartbeatsToStartAndThenQuietSettles() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)

        var state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: .idle
        )
        #expect(state == .idle)
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(1), currentState: state)
        #expect(state == .running)
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(2), currentState: state)
        state = tracker.settleIfQuiet(now: submittedAt.addingTimeInterval(4.9), quietInterval: 3, currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: submittedAt.addingTimeInterval(5), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func submittedCommand_candidateExpiresAtTwoSeconds() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)
        var state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: .idle
        )
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(2), currentState: state)
        #expect(state == .idle)
    }

    @Test
    func genericInteractionCancelsSubmissionCandidate() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)
        var state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: .idle
        )
        tracker.recordUserInteraction()
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(1), currentState: state)
        #expect(state == .idle)
    }

    @Test
    func emptyCommandFinishPreservesBlankSuppressionForLaterGrowth() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(
            totalRows: 10, at: submittedAt.addingTimeInterval(-1), currentState: .idle
        )
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: false)
        state = tracker.markCommandFinished(currentState: state)
        state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.7), currentState: state
        )
        #expect(state == .idle)
    }

    @Test
    func blankSubmissionSuppressesImmediateGrowthThenExpires() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(
            totalRows: 10, at: submittedAt.addingTimeInterval(-1), currentState: .idle
        )
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: false)

        state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: state
        )
        state = tracker.markTerminalActivity(at: submittedAt.addingTimeInterval(1), currentState: state)
        #expect(state == .idle)

        state = tracker.markOutputActivity(
            totalRows: 30, at: submittedAt.addingTimeInterval(2), currentState: state
        )
        #expect(state == .running)
    }

    @Test
    func commandFinishWhileIdleRebasesRowGrowth_lateHeartbeatCannotStartRun() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(
            totalRows: 10, at: submittedAt.addingTimeInterval(-1), currentState: .idle
        )
        tracker.recordUserInteraction()
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: false, hasContent: true)

        // A fast command (`ls`) whose output chunks were all dropped by the
        // 500ms leading-edge heartbeat throttle: OSC 133;D arrives while the
        // pane still reads idle, so the completion itself shows nothing.
        state = tracker.markCommandFinished(currentState: state)
        #expect(state == .idle)

        // The next emitted heartbeat carries the finished command's row
        // growth. It must rebase, not start a quiet-settle activity run for a
        // command that already ended.
        state = tracker.markOutputActivity(
            totalRows: 30, at: submittedAt.addingTimeInterval(0.6), currentState: state
        )
        #expect(state == .idle)

        // Genuinely new growth after the rebase still starts a run.
        state = tracker.markOutputActivity(
            totalRows: 40, at: submittedAt.addingTimeInterval(1.2), currentState: state
        )
        #expect(state == .running)
    }

    @Test
    func foregroundReturnToShellRebasesRowGrowth() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(totalRows: 10, at: start, currentState: .idle)
        state = tracker.refreshForeground(
            name: "find", pid: 42, foregroundIsShell: false, terminalInputIsRaw: false,
            currentState: state
        )
        #expect(state == .running)

        // The command's output tail was dropped by the heartbeat throttle
        // before the poll saw its process exit.
        state = tracker.refreshForeground(
            name: "zsh", pid: 7, foregroundIsShell: true, terminalInputIsRaw: false,
            currentState: state
        )
        #expect(state == .done)

        // After the completion is acknowledged, the late heartbeat carrying
        // that tail must rebase instead of restarting the finished command.
        state = tracker.markOutputActivity(
            totalRows: 30, at: start.addingTimeInterval(1), currentState: .idle
        )
        #expect(state == .idle)
    }

    @Test
    func progressTransitionCancelsSubmissionCandidate() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)
        var state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.2), currentState: .idle
        )
        state = tracker.markProgressStarted(currentState: state)
        state = tracker.markProgressFinished(currentState: state)
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(0.7), currentState: state)
        #expect(state == .done)
    }

    @Test
    func unchangedRawPiPreservesSubmissionButForegroundChangeCancelsIt() {
        let submittedAt = Date(timeIntervalSince1970: 100)
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "pi", pid: 42, foregroundIsShell: false, terminalInputIsRaw: true, currentState: .idle
        )
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)
        state = tracker.refreshForeground(
            name: "pi", pid: 42, foregroundIsShell: false, terminalInputIsRaw: true, currentState: state
        )
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: state)
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(1), currentState: state)
        #expect(state == .running)

        var changedTracker = TerminalExecutionTracker()
        changedTracker.recordUserInteraction()
        _ = changedTracker.refreshForeground(
            name: "pi", pid: 42, foregroundIsShell: false, terminalInputIsRaw: true, currentState: .idle
        )
        changedTracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: true, hasContent: true)
        _ = changedTracker.refreshForeground(
            name: "node", pid: 43, foregroundIsShell: false, terminalInputIsRaw: true, currentState: .idle
        )
        var changedState = changedTracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: .idle
        )
        changedState = changedTracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(1), currentState: changedState
        )
        #expect(changedState == .idle)
    }

    @Test
    func unrecognizedRawProgramCannotArmInPlaceOutputStart() {
        var tracker = TerminalExecutionTracker()
        let submittedAt = Date(timeIntervalSince1970: 100)
        tracker.recordCommandSubmission(at: submittedAt, allowInPlaceOutputStart: false, hasContent: true)
        var state = tracker.markOutputActivity(
            totalRows: 20, at: submittedAt.addingTimeInterval(0.5), currentState: .idle
        )
        state = tracker.markOutputActivity(totalRows: 20, at: submittedAt.addingTimeInterval(1), currentState: state)
        #expect(state == .idle)
    }

    @Test
    func startupOutputCannotUseSubmissionPath() {
        var tracker = TerminalExecutionTracker()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markOutputActivity(totalRows: 20, at: start, currentState: .idle)
        state = tracker.markOutputActivity(totalRows: 20, at: start.addingTimeInterval(0.5), currentState: state)
        #expect(state == .idle)
    }
}
