import Foundation
@testable import Macterm
import Testing

/// Direct unit tests for `TerminalExecutionTracker`, the state machine behind a
/// pane's tab status spinner.
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
    func renderActivity_fromDoneWithoutForeground_staysDone() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()

        let state = tracker.markTerminalActivity(
            at: Date(timeIntervalSince1970: 100),
            kind: .render,
            currentState: .done
        )

        #expect(state == .done)
    }

    @Test
    func markTerminalActivity_fromRunning_keepsAliveAndRefreshesTimestamp() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markTerminalActivity(at: start, currentState: .idle)
        #expect(state == .running)

        state = tracker.markTerminalActivity(at: start.addingTimeInterval(2), currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .running)

        state = tracker.settleIfQuiet(now: start.addingTimeInterval(5), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func activitySourcedRun_settlesAfterQuietInterval() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markTerminalActivity(at: start, currentState: .idle)
        #expect(state == .running)

        state = tracker.settleIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3, currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func progressStarted_withoutInteraction_isStillRunningSignal() {
        var tracker = TerminalExecutionTracker()

        let state = tracker.markProgressStarted(currentState: .idle)

        #expect(state == .running)
    }

    @Test
    func progressStarted_replacesRestoredDoneWithoutInteraction() {
        var tracker = TerminalExecutionTracker()

        let state = tracker.markProgressStarted(currentState: .done)

        #expect(state == .running)
    }

    @Test
    func terminalActivity_fromDoneWithInteractionRestartsRun() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()

        let state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 100), currentState: .done)

        #expect(state == .running)
    }

    @Test
    func rawForegroundChange_fromDoneIsRunningSignal() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "sleep",
            pid: 42,
            foregroundIsShell: false,
            terminalInputIsRaw: false,
            currentState: .idle
        )
        state = tracker.refreshForeground(
            name: "zsh",
            pid: 43,
            foregroundIsShell: true,
            terminalInputIsRaw: false,
            currentState: state
        )
        #expect(state == .done)

        state = tracker.refreshForeground(
            name: "btop",
            pid: 44,
            foregroundIsShell: false,
            terminalInputIsRaw: true,
            currentState: state
        )

        #expect(state == .running)
    }

    @Test
    func progressFinishedForeground_laterActivityRestartsRun() {
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.refreshForeground(
            name: "node",
            pid: 42,
            foregroundIsShell: false,
            terminalInputIsRaw: false,
            currentState: .idle
        )
        state = tracker.markProgressStarted(currentState: state)
        state = tracker.markProgressFinished(currentState: state)
        #expect(state == .done)

        state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 100), currentState: state)

        #expect(state == .running)
    }
}
