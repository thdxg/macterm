import Foundation
@testable import Macterm
import Testing

struct PollCadenceTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t)
    }

    private let activeVisible = PollCadence.Context(
        isAppActive: true, isAnyWindowVisible: true, isAnyPaneBusy: false
    )
    private let inactiveVisible = PollCadence.Context(
        isAppActive: false, isAnyWindowVisible: true, isAnyPaneBusy: false
    )
    private let hidden = PollCadence.Context(
        isAppActive: false, isAnyWindowVisible: false, isAnyPaneBusy: false
    )

    // MARK: - Mode table

    @Test
    func active_and_idle_with_no_events_is_idle_cadence() {
        let cadence = PollCadence()
        #expect(cadence.mode(at: date(100), context: activeVisible) == .idle)
        #expect(cadence.nextDelay(at: date(100), context: activeVisible) == PollCadence.idleInterval)
    }

    @Test
    func recent_event_holds_fast_cadence_until_burst_expires() {
        var cadence = PollCadence()
        _ = cadence.noteEvent(at: date(100))
        #expect(cadence.mode(at: date(100), context: activeVisible) == .fast)
        #expect(cadence.mode(at: date(100 + PollCadence.burstWindow - 0.1), context: activeVisible) == .fast)
        #expect(cadence.mode(at: date(100 + PollCadence.burstWindow), context: activeVisible) == .idle)
    }

    @Test
    func busy_pane_holds_fast_cadence_only_while_app_active() {
        let cadence = PollCadence()
        var busy = activeVisible
        busy.isAnyPaneBusy = true
        #expect(cadence.mode(at: date(100), context: busy) == .fast)

        var busyInactive = inactiveVisible
        busyInactive.isAnyPaneBusy = true
        #expect(cadence.mode(at: date(100), context: busyInactive) == .background)
    }

    @Test
    func inactive_with_visible_window_is_background_not_paused() {
        // Sidebar titles must not visibly freeze while another app is
        // frontmost with the Macterm window still on screen.
        let cadence = PollCadence()
        #expect(cadence.mode(at: date(100), context: inactiveVisible) == .background)
        #expect(cadence.nextDelay(at: date(100), context: inactiveVisible) == PollCadence.backgroundInterval)
    }

    @Test
    func nothing_visible_pauses_the_timer_entirely() {
        let cadence = PollCadence()
        #expect(cadence.mode(at: date(100), context: hidden) == .paused)
        #expect(cadence.nextDelay(at: date(100), context: hidden) == nil)
    }

    @Test
    func visibility_outranks_burst_for_pausing() {
        // An event with nothing on screen must not keep a timer alive.
        var cadence = PollCadence()
        _ = cadence.noteEvent(at: date(100))
        #expect(cadence.mode(at: date(100), context: hidden) == .paused)
        #expect(cadence.nextDelay(at: date(100), context: hidden) == nil)
    }

    @Test
    func quick_terminal_typing_is_fast_despite_inactive_app() {
        // The quick terminal panel is non-activating: keystrokes arrive while
        // NSApp.isActive is false. The event burst must still win.
        var cadence = PollCadence()
        _ = cadence.noteEvent(at: date(100))
        #expect(cadence.mode(at: date(100.1), context: inactiveVisible) == .fast)
    }

    // MARK: - Event coalescing & resume

    @Test
    func first_event_always_polls_immediately() {
        var cadence = PollCadence()
        #expect(cadence.noteEvent(at: date(100)) == true)
    }

    @Test
    func event_right_after_a_poll_coalesces() {
        var cadence = PollCadence()
        cadence.notePolled(at: date(100))
        #expect(cadence.noteEvent(at: date(100.1)) == false)
        // Coalesced, but the burst must still be recorded for cadence.
        #expect(cadence.mode(at: date(100.1), context: activeVisible) == .fast)
    }

    @Test
    func event_after_the_fast_interval_polls_immediately() {
        var cadence = PollCadence()
        cadence.notePolled(at: date(100))
        #expect(cadence.noteEvent(at: date(100 + PollCadence.fastInterval)) == true)
    }

    @Test
    func resume_after_long_pause_polls_immediately() {
        var cadence = PollCadence()
        cadence.notePolled(at: date(100))
        // Hours later (e.g. window unhidden after a night minimized) the
        // first event must produce an instant tick, not wait an interval.
        #expect(cadence.noteEvent(at: date(10000)) == true)
    }

    @Test
    func event_storm_never_exceeds_fast_cadence() {
        var cadence = PollCadence()
        var polls = 0
        var t = 100.0
        for _ in 0 ..< 100 {
            if cadence.noteEvent(at: date(t)) {
                polls += 1
                cadence.notePolled(at: date(t))
            }
            t += 0.01 // 100Hz keystroke/render storm for 1s
        }
        // 1s of storm at fast cadence = at most 1 initial + 4 coalesced polls.
        #expect(polls <= 5)
    }
}
