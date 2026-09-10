@testable import Macterm
import Testing

/// The permission policy as a pure function — no alert, no defaults domain.
@MainActor
struct IntentPermissionTests {
    @Test
    func allow_never_asks() {
        #expect(IntentPermission.decide(access: .allow, recorded: nil, isHarnessRun: false) == .allow)
        // A recorded "no" cannot override an explicit allow: the preference is
        // the standing decision and the record only exists for `.ask`.
        #expect(IntentPermission.decide(access: .allow, recorded: false, isHarnessRun: false) == .allow)
    }

    @Test
    func deny_refuses_even_under_the_harness() {
        #expect(IntentPermission.decide(access: .deny, recorded: nil, isHarnessRun: false) == .deny)
        #expect(IntentPermission.decide(access: .deny, recorded: true, isHarnessRun: false) == .deny)
        // The harness skip exists to avoid a modal nobody can answer, not to
        // override a decision the user already made.
        #expect(IntentPermission.decide(access: .deny, recorded: nil, isHarnessRun: true) == .deny)
    }

    @Test
    func ask_prompts_once_then_replays_the_answer() {
        #expect(IntentPermission.decide(access: .ask, recorded: nil, isHarnessRun: false) == .ask)
        #expect(IntentPermission.decide(access: .ask, recorded: true, isHarnessRun: false) == .allow)
        #expect(IntentPermission.decide(access: .ask, recorded: false, isHarnessRun: false) == .deny)
    }

    @Test
    func ask_under_the_harness_allows_without_a_modal() {
        // The harnesses hand the app a throwaway HOME and drive it with nobody
        // at the keyboard, so the alert would block the launch run loop. It
        // resolves to allow rather than deny because a hermetic instance is the
        // harness's own to drive.
        #expect(IntentPermission.decide(access: .ask, recorded: nil, isHarnessRun: true) == .allow)
    }

    @Test
    func the_stored_value_round_trips_and_an_unknown_one_is_not_a_case() {
        for access in ShortcutsAccess.allCases {
            #expect(ShortcutsAccess(rawValue: access.rawValue) == access)
        }
        // What `Preferences.init` relies on to fall back to `.ask`.
        #expect(ShortcutsAccess(rawValue: "sometimes") == nil)
    }
}

/// The gate's own bookkeeping: it asks once per launch and remembers.
///
/// Serialized because `IntentPermissionGate.shared` is a singleton and
/// swift-testing runs suites in parallel.
@Suite(.serialized)
@MainActor
struct IntentPermissionGateTests {
    @Test
    func an_ask_is_put_up_once_and_the_answer_is_reused() throws {
        let gate = IntentPermissionGate.shared
        defer { gate.resetForTesting() }
        gate.resetForTesting()
        var asked = 0
        gate.access = { .ask }
        gate.presentAlert = {
            asked += 1
            return true
        }

        try gate.authorize()
        try gate.authorize()

        #expect(asked == 1)
    }

    @Test
    func a_refused_ask_denies_every_later_intent_in_the_run() {
        let gate = IntentPermissionGate.shared
        defer { gate.resetForTesting() }
        gate.resetForTesting()
        var asked = 0
        gate.access = { .ask }
        gate.presentAlert = {
            asked += 1
            return false
        }

        #expect(throws: MactermIntentError.self) { try gate.authorize() }
        #expect(throws: MactermIntentError.self) { try gate.authorize() }

        // Ghostty caches only an Allow, so a "Don't Allow" there re-asks on the
        // next intent. Macterm remembers both, so declining once is not a
        // question the user gets asked again in the same launch.
        #expect(asked == 1)
    }

    @Test
    func deny_never_reaches_the_alert() {
        let gate = IntentPermissionGate.shared
        defer { gate.resetForTesting() }
        gate.resetForTesting()
        var asked = 0
        gate.access = { .deny }
        gate.presentAlert = {
            asked += 1
            return true
        }

        #expect(throws: MactermIntentError.self) { try gate.authorize() }
        #expect(asked == 0)
    }

    @Test
    func the_preference_is_read_on_every_authorize_so_a_change_needs_no_restart() throws {
        let gate = IntentPermissionGate.shared
        defer { gate.resetForTesting() }
        gate.resetForTesting()
        var current = ShortcutsAccess.deny
        gate.access = { current }
        gate.presentAlert = { true }

        #expect(throws: MactermIntentError.self) { try gate.authorize() }
        current = .allow
        try gate.authorize()
    }
}
