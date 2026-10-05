@testable import Macterm
import Testing

struct RemoteTitleConfirmationTests {
    @Test
    func a_held_title_waits_for_a_probe_sent_after_it() {
        var confirmation = RemoteTitleConfirmation()
        confirmation.noteProbeDispatched()
        confirmation.hold("✳ task")
        #expect(confirmation.resolve(programInFront: true) == .undecided)
        #expect(confirmation.awaitsProbe)
        confirmation.noteProbeDispatched()
        #expect(confirmation.resolve(programInFront: true) == .adopt("✳ task"))
        #expect(!confirmation.awaitsProbe)
    }

    @Test
    func a_shell_in_front_clears() {
        var confirmation = RemoteTitleConfirmation()
        confirmation.hold("~/dev")
        confirmation.noteProbeDispatched()
        #expect(confirmation.resolve(programInFront: false) == .clear)
        #expect(!confirmation.awaitsProbe)
    }

    @Test
    func a_demoted_title_is_kept_or_cleared() {
        var kept = RemoteTitleConfirmation()
        kept.demoteShown()
        kept.noteProbeDispatched()
        #expect(kept.resolve(programInFront: true) == .adopt(nil))

        var cleared = RemoteTitleConfirmation()
        cleared.demoteShown()
        cleared.noteProbeDispatched()
        #expect(cleared.resolve(programInFront: false) == .clear)
    }

    @Test
    func nothing_waiting_decides_nothing() {
        var confirmation = RemoteTitleConfirmation()
        confirmation.noteProbeDispatched()
        #expect(confirmation.resolve(programInFront: false) == .undecided)
    }

    @Test
    func a_change_after_dispatch_voids_that_answer() {
        // Each of these lands while a probe is in flight; its answer then says
        // nothing about the new state.
        let changes: [(inout RemoteTitleConfirmation) -> Void] = [
            { $0.hold("✳ newer") },
            { $0.demoteShown() },
            { $0.dropPending() },
            { $0.reset() },
        ]
        for change in changes {
            var confirmation = RemoteTitleConfirmation()
            confirmation.hold("✳ task")
            confirmation.noteProbeDispatched()
            change(&confirmation)
            #expect(confirmation.resolve(programInFront: true) == .undecided)
        }
    }

    @Test
    func the_same_title_held_again_leaves_the_probe_in_flight_valid() {
        // A program re-emitting its idle title must not keep voiding probes,
        // or a title re-emitted faster than a round trip is never confirmed.
        var confirmation = RemoteTitleConfirmation()
        confirmation.hold("✳ task")
        confirmation.noteProbeDispatched()
        confirmation.hold("✳ task")
        #expect(confirmation.resolve(programInFront: true) == .adopt("✳ task"))
        #expect(!confirmation.awaitsProbe)
    }

    @Test
    func dropping_the_held_title_keeps_a_demoted_one() {
        var confirmation = RemoteTitleConfirmation()
        confirmation.demoteShown()
        confirmation.hold("✳ task")
        confirmation.dropPending()
        #expect(confirmation.pending == nil)
        #expect(confirmation.shownUnconfirmed)
        confirmation.noteProbeDispatched()
        #expect(confirmation.resolve(programInFront: true) == .adopt(nil))
    }
}
