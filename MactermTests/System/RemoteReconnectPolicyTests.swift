import Foundation
@testable import Macterm
import Testing

struct RemoteReconnectPolicyTests {
    private let pane = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func first_attempt_is_immediate() {
        let policy = RemoteReconnectPolicy()
        #expect(policy.shouldAttempt(pane, now: epoch))
    }

    @Test
    func backoff_escalates_with_consecutive_attempts() {
        var policy = RemoteReconnectPolicy()
        var now = epoch

        // 1st attempt recorded → 2nd gated by backoff[1] (5s).
        policy.recordAttempt(pane, now: now)
        #expect(!policy.shouldAttempt(pane, now: now + 4))
        #expect(policy.shouldAttempt(pane, now: now + 5))

        // 2nd attempt → gated by backoff[2] (20s).
        now += 5
        policy.recordAttempt(pane, now: now)
        #expect(!policy.shouldAttempt(pane, now: now + 19))
        #expect(policy.shouldAttempt(pane, now: now + 20))

        // 3rd attempt → backoff[3] (60s), and the last entry repeats for
        // every attempt after (a host down for a day gets one attempt per
        // ≥60s-spaced trigger, never a tighter loop).
        now += 20
        policy.recordAttempt(pane, now: now)
        #expect(!policy.shouldAttempt(pane, now: now + 59))
        #expect(policy.shouldAttempt(pane, now: now + 60))
        now += 60
        policy.recordAttempt(pane, now: now)
        #expect(!policy.shouldAttempt(pane, now: now + 59))
        #expect(policy.shouldAttempt(pane, now: now + 60))
    }

    @Test
    func alive_observation_resets_the_streak_only_after_the_grace_period() {
        var policy = RemoteReconnectPolicy()
        policy.recordAttempt(pane, now: epoch)

        // A dial still in flight looks alive (processExited == false) for up
        // to the TCP connect timeout — it must NOT reset the backoff.
        policy.observeAlive(pane, now: epoch + 30)
        #expect(!policy.shouldAttempt(pane, now: epoch + 1))

        // Surviving past the grace window means the reconnect really took.
        policy.observeAlive(pane, now: epoch + RemoteReconnectPolicy.recoveryGrace)
        policy.recordAttempt(pane, now: epoch + 200)
        // Streak restarted at 1 → back to the 5s gate, not 20s.
        #expect(policy.shouldAttempt(pane, now: epoch + 205))
    }

    @Test
    func forget_clears_all_state_for_a_closed_pane() {
        var policy = RemoteReconnectPolicy()
        policy.recordAttempt(pane, now: epoch)
        policy.forget(pane)
        #expect(policy.shouldAttempt(pane, now: epoch))
    }

    @Test
    func panes_are_gated_independently() {
        var policy = RemoteReconnectPolicy()
        let other = UUID()
        policy.recordAttempt(pane, now: epoch)
        #expect(policy.shouldAttempt(other, now: epoch))
    }
}
