import Foundation

/// Rate limit on the work a reported OSC 0/2 title costs the main thread.
///
/// Every title arrival is a command boundary, so `Pane.receiveReportedTitle`
/// answers it with a provenance lookup and a full foreground refresh: three
/// `KERN_PROCARGS2` reads plus an `open` + `tcgetattr` on the session's tty,
/// ~100µs together. A program renaming its session every few seconds affords
/// that; a zmx session replaying prompt-heavy scrollback at launch does not —
/// nushell and Starship set a title per prompt, and 150k of them measured as
/// the main thread frozen for 14s, the control socket unanswered throughout.
///
/// Leading edge plus one trailing flush per window: the first title after a
/// quiet `interval` is evaluated on the spot, so an interactive title still
/// lands at once. Every title arriving inside the window is held — only the
/// newest kept — and the caller is told, once per window, to `flush` at the
/// window's end. A flood therefore costs one evaluation per window, and no
/// title is lost: the newest is evaluated at most `interval` late, against
/// the foreground holding the pane THEN — the answer the poll's own next
/// tick would have given, which is why the interval is the poll's fast
/// cadence (`PollCadence.fastInterval`).
///
/// A value type with an injected clock, in the `PollCadence` style; `Pane`
/// owns one per pane and the flush timer.
struct TitleReportThrottle: Equatable {
    enum Verdict: Equatable {
        /// Evaluate the title now.
        case evaluate
        /// The title is held (replacing any earlier held one). A non-nil
        /// delay asks the caller to `flush` after that many seconds; nil
        /// means a flush for this window is already scheduled.
        case held(flushAfter: TimeInterval?)
    }

    let interval: TimeInterval

    private var lastEvaluatedAt: Date?
    private(set) var heldTitle: String?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func receive(_ title: String, at now: Date) -> Verdict {
        if let lastEvaluatedAt {
            let elapsed = now.timeIntervalSince(lastEvaluatedAt)
            if elapsed >= 0, elapsed < interval {
                let flushAfter: TimeInterval? = heldTitle == nil ? interval - elapsed : nil
                heldTitle = title
                return .held(flushAfter: flushAfter)
            }
        }
        lastEvaluatedAt = now
        heldTitle = nil
        return .evaluate
    }

    /// The held title now due for evaluation, or nil when nothing is held.
    /// Evaluating it opens a new window, so a flood keeps costing one
    /// evaluation per `interval` for as long as it lasts.
    mutating func flush(at now: Date) -> String? {
        guard let title = heldTitle else { return nil }
        heldTitle = nil
        lastEvaluatedAt = now
        return title
    }

    /// Forget everything: the next title is evaluated at once. For a pane
    /// whose scheduled flush was cancelled with its surface.
    mutating func reset() {
        lastEvaluatedAt = nil
        heldTitle = nil
    }
}
