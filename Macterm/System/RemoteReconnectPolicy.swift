import Foundation

/// Attempt gating for reconnecting dropped remote panes (#281). Pure state
/// machine — no clocks, no I/O — so `AppState` owns the triggers (system
/// wake, app activation, project selection) and this type only answers "may
/// this pane be redialed NOW?". Two properties matter:
///
/// - **It can never loop.** Attempts happen only when a trigger fires a sweep;
///   between triggers nothing is scheduled. The backoff below additionally
///   bounds how often repeated triggers (a wake burst, cmd-tab churn) may
///   retry one pane whose host is still unreachable.
/// - **Recovery is judged by survival, not by the attempt.** A respawned ssh
///   against a silently dead host can sit in TCP connect for ~75s looking
///   "alive" (`processExited == false`) before it fails, so a pane only
///   clears its failure streak after staying alive for `recoveryGrace` —
///   otherwise every dial-in-progress would reset the backoff.
struct RemoteReconnectPolicy {
    /// Minimum quiet time before a pane may be attempted again, indexed by its
    /// consecutive-attempt streak (0 attempts → immediate, then escalating;
    /// the last entry repeats).
    static let backoff: [TimeInterval] = [0, 5, 20, 60]

    /// How long a previously-attempted pane must stay alive before the
    /// attempt is judged successful and its streak resets. Longer than the
    /// worst-case TCP connect hang, so a dial still in flight never counts.
    static let recoveryGrace: TimeInterval = 120

    private struct PaneState {
        var lastAttempt: Date
        var streak: Int
    }

    private var states: [UUID: PaneState] = [:]

    /// Whether the pane's backoff window has elapsed. Does not record — call
    /// `recordAttempt` when the reconnect is actually issued.
    func shouldAttempt(_ paneID: UUID, now: Date) -> Bool {
        guard let state = states[paneID] else { return true }
        let delay = Self.backoff[min(state.streak, Self.backoff.count - 1)]
        return now.timeIntervalSince(state.lastAttempt) >= delay
    }

    mutating func recordAttempt(_ paneID: UUID, now: Date) {
        let streak = (states[paneID]?.streak ?? 0) + 1
        states[paneID] = PaneState(lastAttempt: now, streak: streak)
    }

    /// A sweep found the pane alive. Clears the streak only once the pane has
    /// outlived `recoveryGrace` since its last attempt (see the type comment).
    mutating func observeAlive(_ paneID: UUID, now: Date) {
        guard let state = states[paneID] else { return }
        if now.timeIntervalSince(state.lastAttempt) >= Self.recoveryGrace {
            states[paneID] = nil
        }
    }

    /// The pane is gone for good — drop its state.
    mutating func forget(_ paneID: UUID) {
        states[paneID] = nil
    }
}
