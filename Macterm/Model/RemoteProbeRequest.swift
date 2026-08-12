import Foundation

/// The pending-probe request state for one remote pane: whether the pane's
/// host should be probed immediately (bypassing `RemoteForegroundResolver`'s
/// per-host throttle) and the bounded retry budget that keeps a request
/// alive through the session-registration race.
///
/// Value type owned by `Pane` (behind `@ObservationIgnored` — the request is
/// plumbing, never UI state). `Pane` guards the isRemote/never-named
/// conditions; this type owns only the request/consume/retry mechanics, so
/// they can be tested without a pane.
struct RemoteProbeRequest {
    /// True when a probe should fire now. Primed at init for remote panes:
    /// scheduled probes cover only the frontmost project, so a restored pane
    /// in a background project would otherwise never be probed at all.
    private(set) var isPending: Bool

    /// Bounded retries while the pane has never been named: a freshly
    /// spawned session registers on the host asynchronously (ssh handshake +
    /// zmx startup, seconds), so the primed init probe usually fires too
    /// early and finds no session. Consuming that request would strand the
    /// pane nil forever if its project leaves the frontmost slot inside the
    /// registration window. The local mirror is `AppState.zmxRetryBudget`
    /// for `zmx ls` racing session registration. Sixteen because retries
    /// pace at roughly max(poll tick, probe RTT) ≈ 1–2s (a pending request
    /// bypasses the resolver's interval), and registration on a slow host
    /// measures ~12–14s: the budget must outlive the window it exists to
    /// cover, with margin. Bounded so a session that will never appear
    /// (killed remotely) can't keep re-arming probes.
    private var retryBudget = 16

    init(primed: Bool) {
        isPending = primed
    }

    /// A boundary crossed (execution transition, OSC 133;D) — probe now.
    mutating func request() {
        isPending = true
    }

    /// The resolver fired a probe covering this pane's host — the pending
    /// request is answered.
    mutating func consume() {
        isPending = false
    }

    /// The probe succeeded but its listing had no entry for this pane's
    /// session (the registration race above). Re-arm, bounded.
    mutating func noteMiss() {
        guard retryBudget > 0 else { return }
        retryBudget -= 1
        isPending = true
    }
}
