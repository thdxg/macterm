import Foundation
@testable import Macterm
import Testing

struct TitleReportThrottleTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t)
    }

    /// The flush delay a `.held` verdict asks for, or nil for `.evaluate` /
    /// a window whose flush is already scheduled. Compared to the
    /// microsecond: the delay is `interval` minus an elapsed time between two
    /// `Date`s, which store seconds since 2001 as a Double and so carry
    /// ~1e-8 of error at these values.
    private func flushDelay(_ verdict: TitleReportThrottle.Verdict) -> TimeInterval? {
        if case let .held(flushAfter) = verdict { return flushAfter }
        return nil
    }

    private func isHeld(_ verdict: TitleReportThrottle.Verdict, flushAfter expected: TimeInterval) -> Bool {
        guard let delay = flushDelay(verdict) else { return false }
        return abs(delay - expected) < 1e-6
    }

    @Test
    func first_title_is_evaluated_at_once() {
        var throttle = TitleReportThrottle(interval: 0.25)
        #expect(throttle.receive("a", at: date(100)) == .evaluate)
        #expect(throttle.heldTitle == nil)
        #expect(throttle.flush(at: date(100.25)) == nil)
    }

    @Test
    func titles_inside_the_window_are_held_and_the_newest_wins() {
        var throttle = TitleReportThrottle(interval: 0.25)
        #expect(throttle.receive("a", at: date(100)) == .evaluate)
        // The first held title asks for exactly one flush, at the window's end.
        #expect(isHeld(throttle.receive("b", at: date(100.1)), flushAfter: 0.15))
        // Later ones inside the same window ask for nothing more.
        #expect(throttle.receive("c", at: date(100.2)) == .held(flushAfter: nil))
        #expect(throttle.heldTitle == "c")
        #expect(throttle.flush(at: date(100.25)) == "c")
        #expect(throttle.heldTitle == nil)
    }

    @Test
    func a_flush_opens_a_new_window() {
        var throttle = TitleReportThrottle(interval: 0.25)
        _ = throttle.receive("a", at: date(100))
        _ = throttle.receive("b", at: date(100.1))
        #expect(throttle.flush(at: date(100.25)) == "b")
        // Still flooding: the next title is held against the window the
        // flush opened, not evaluated — one evaluation per interval.
        #expect(isHeld(throttle.receive("c", at: date(100.3)), flushAfter: 0.2))
        #expect(throttle.flush(at: date(100.5)) == "c")
    }

    @Test
    func a_title_after_a_quiet_window_is_evaluated_again() {
        var throttle = TitleReportThrottle(interval: 0.25)
        #expect(throttle.receive("a", at: date(100)) == .evaluate)
        #expect(throttle.receive("b", at: date(100.25)) == .evaluate)
        #expect(throttle.receive("c", at: date(103)) == .evaluate)
        #expect(throttle.heldTitle == nil)
    }

    @Test
    func a_flood_costs_one_evaluation_per_window() {
        var throttle = TitleReportThrottle(interval: 0.25)
        var evaluations = 0
        var flushes = 0
        var flushDue: Date?
        // 10k titles over one second, ~100µs apart — the launch replay shape.
        for i in 0 ..< 10000 {
            let now = date(100 + Double(i) * 0.0001)
            if let due = flushDue, now >= due {
                flushDue = nil
                if throttle.flush(at: now) != nil { flushes += 1 }
            }
            switch throttle.receive("t\(i)", at: now) {
            case .evaluate:
                evaluations += 1
            case let .held(flushAfter?):
                flushDue = now.addingTimeInterval(flushAfter)
            case .held(nil):
                break
            }
        }
        #expect(evaluations == 1)
        #expect(flushes == 3)
        // The newest title is what's waiting, nothing older.
        #expect(throttle.heldTitle == "t9999")
    }

    @Test
    func reset_forgets_the_window_and_the_held_title() {
        var throttle = TitleReportThrottle(interval: 0.25)
        _ = throttle.receive("a", at: date(100))
        _ = throttle.receive("b", at: date(100.1))
        throttle.reset()
        #expect(throttle.heldTitle == nil)
        #expect(throttle.receive("c", at: date(100.2)) == .evaluate)
    }

    @Test
    func a_clock_that_went_backwards_evaluates() {
        var throttle = TitleReportThrottle(interval: 0.25)
        _ = throttle.receive("a", at: date(100))
        #expect(throttle.receive("b", at: date(99)) == .evaluate)
    }
}
