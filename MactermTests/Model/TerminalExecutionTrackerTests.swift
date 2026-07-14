import Foundation
@testable import Macterm
import Testing

/// Direct unit tests for `TerminalExecutionTracker`, the state machine behind a
/// pane's tab status spinner.
///
/// These pin the core invariant surfaced in the activity-detection fix: a
/// render/output heartbeat can keep an already-running command active (so
/// in-place spinners that repaint with carriage returns stay alive), but it can
/// never start or resurrect the spinner on its own. The "keep-alive only" rule
/// is enforced at the call site (`onTerminalRender` only calls the heartbeat
/// while already `.running`), and these tests lock the matching guarantee into
/// the tracker itself — otherwise a future refactor could silently reintroduce
/// the "prompt redraw keeps spinning" bug with nothing to catch it.
struct TerminalExecutionTrackerTests {
    @Test
    func markTerminalActivity_fromIdleWithoutInteraction_staysIdle() {
        // No prior user interaction: a fresh/restored shell's startup output
        // must not register as activity.
        var tracker = TerminalExecutionTracker()
        let state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 1), currentState: .idle)
        #expect(state == .idle)
    }

    @Test
    func markTerminalActivity_fromIdleWithInteraction_startsRun() {
        // Output activity (scrollback) after interaction is a genuine signal
        // that something is running, so — unlike a render heartbeat — it *may*
        // start the spinner from idle. Pinned here so the "render can't start"
        // guard isn't over-corrected into "no activity can ever start".
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 1), currentState: .idle)
        #expect(state == .running)
    }

    @Test
    func markTerminalActivity_fromDone_doesNotReturnToRunning() {
        // A finished command (`.done`, checkmark showing) must not be flipped
        // back to running by a render/output heartbeat — e.g. a background job
        // printing while the foreground command is already settled.
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        var state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 100), currentState: .idle)
        state = tracker.settleIfQuiet(now: Date(timeIntervalSince1970: 103), quietInterval: 3, currentState: state)
        #expect(state == .done)

        state = tracker.markTerminalActivity(at: Date(timeIntervalSince1970: 110), currentState: state)
        #expect(state == .done)
    }

    @Test
    func markTerminalActivity_fromRunning_keepsAliveAndRefreshesTimestamp() {
        // While running, each heartbeat refreshes the activity timestamp so the
        // quiet-settle window restarts. This is "a render can keep a spinner
        // alive" — the fix for in-place spinners that repaint the same line.
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markTerminalActivity(at: start, currentState: .idle)
        #expect(state == .running)

        // A heartbeat at start+2 restarts the window; settling at start+3 (only
        // 1s after the last heartbeat) must still be running.
        state = tracker.markTerminalActivity(at: start.addingTimeInterval(2), currentState: state)
        #expect(state == .running)
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .running)

        // After the full quiet interval elapses past the last heartbeat, it settles.
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(5), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }

    @Test
    func activitySourcedRun_settlesAfterQuietInterval() {
        // An activity-sourced run is not held forever: once output goes quiet
        // for the interval it decays to `.done` (foreground- and progress-sourced
        // runs are not subject to this timer).
        var tracker = TerminalExecutionTracker()
        tracker.recordUserInteraction()
        let start = Date(timeIntervalSince1970: 100)
        var state = tracker.markTerminalActivity(at: start, currentState: .idle)
        #expect(state == .running)

        // Just under the quiet interval: still running.
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3, currentState: state)
        #expect(state == .running)
        // At the quiet interval: settles to done.
        state = tracker.settleIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3, currentState: state)
        #expect(state == .done)
    }
}
