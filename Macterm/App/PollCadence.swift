import Foundation

/// Pure cadence policy for the foreground-process poll. Owns no timers:
/// `AppState` feeds it events plus a `Context` snapshot and re-arms a single
/// non-repeating timer from `nextDelay`. Value type with an injected clock,
/// in the `TerminalExecutionTracker` style, so the whole state machine is
/// unit-testable without AppKit.
///
/// The cadence exists because a fixed 250ms poll is the app's last
/// structural idle cost (~0.9% of a core, scaling with pane count, #110).
/// Polling fast is only useful while something is moving; the rest of the
/// time a slower tick — or none at all — preserves every title/status
/// guarantee because each interesting moment (tab switch, OSC title,
/// keystroke, execution transition) also fires an instant-resume event.
struct PollCadence {
    enum Mode: Equatable {
        /// Something happened recently or a command is running: full 250ms.
        case fast
        /// App active but nothing moving: titles stay live at 1s.
        case idle
        /// App inactive but a window is visible (someone may be watching the
        /// sidebar): 2s keeps names from visibly freezing.
        case background
        /// Nothing visible: no timer at all; a later event resumes polling.
        case paused
    }

    /// Snapshot of the world at decision time, computed by the caller from
    /// injected closures so tests control every input.
    struct Context: Equatable {
        var isAppActive: Bool
        var isAnyWindowVisible: Bool
        var isAnyPaneBusy: Bool
    }

    static let fastInterval: TimeInterval = 0.25
    static let idleInterval: TimeInterval = 1.0
    static let backgroundInterval: TimeInterval = 2.0
    /// How long a single event keeps the cadence fast.
    static let burstWindow: TimeInterval = 5.0

    private var lastEventAt: Date?
    private var lastPolledAt: Date?

    /// Record an instant-resume trigger (app activation, occlusion change,
    /// tab switch, OSC title, execution-state transition, user interaction,
    /// wake). Returns true when the caller should poll immediately; false
    /// when a poll already ran within `fastInterval`, so event storms can
    /// never poll faster than the fast cadence.
    mutating func noteEvent(at now: Date) -> Bool {
        lastEventAt = now
        guard let lastPolledAt else { return true }
        return now.timeIntervalSince(lastPolledAt) >= Self.fastInterval
    }

    /// Record that a poll ran. Callers must invoke this *before* the poll's
    /// work: the poll itself publishes execution-state transitions that fire
    /// `noteEvent`, and the fresh timestamp makes those coalesce instead of
    /// recursing into another poll.
    mutating func notePolled(at now: Date) {
        lastPolledAt = now
    }

    func mode(at now: Date, context: Context) -> Mode {
        // Visibility outranks the burst: with nothing on screen there is
        // nobody to show a title to, and the next event restarts everything.
        if !context.isAnyWindowVisible, !context.isAppActive { return .paused }
        if let lastEventAt, now.timeIntervalSince(lastEventAt) < Self.burstWindow { return .fast }
        // The burst above covers the inactive-but-typing quick terminal; a
        // busy pane only holds fast cadence while the app is frontmost.
        if context.isAnyPaneBusy, context.isAppActive { return .fast }
        if context.isAppActive { return .idle }
        return .background
    }

    /// Seconds until the next tick, or nil to stop the timer entirely —
    /// paused polling resumes only via a later `noteEvent`.
    func nextDelay(at now: Date, context: Context) -> TimeInterval? {
        switch mode(at: now, context: context) {
        case .fast: Self.fastInterval
        case .idle: Self.idleInterval
        case .background: Self.backgroundInterval
        case .paused: nil
        }
    }
}
