import Foundation
@testable import Macterm
import Testing

struct TabIndexChordTests {
    @Test
    func a_single_digit_selects_that_tab() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 3, tabCount: 5) == 3)
    }

    @Test
    func a_second_digit_extends_the_number() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 1, tabCount: 12) == 1)
        #expect(chord.press(digit: 2, tabCount: 12) == 12)
    }

    @Test
    func zero_is_reachable_only_as_a_continuation() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 0, tabCount: 12) == nil)
        #expect(chord.press(digit: 1, tabCount: 12) == 1)
        #expect(chord.press(digit: 0, tabCount: 12) == 10)
    }

    @Test
    func three_digits_accumulate() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 1, tabCount: 120) == 1)
        #expect(chord.press(digit: 0, tabCount: 120) == 10)
        #expect(chord.press(digit: 5, tabCount: 120) == 105)
    }

    /// The old single-digit binding's behaviour, preserved: with too few tabs
    /// to hold the extended number, the digit starts a new one.
    @Test
    func a_digit_that_cannot_extend_restarts_the_number() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 1, tabCount: 5) == 1)
        #expect(chord.press(digit: 2, tabCount: 5) == 2)
        #expect(chord.press(digit: 3, tabCount: 5) == 3)
    }

    @Test
    func a_digit_past_the_end_addresses_nothing() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 7, tabCount: 3) == nil)
        #expect(chord.press(digit: 8, tabCount: 0) == nil)
    }

    /// A failed press must not leave the run open — the digit after it starts
    /// clean rather than extending a number the user never saw selected.
    @Test
    func a_failed_press_ends_the_run() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 1, tabCount: 12) == 1)
        #expect(chord.press(digit: 9, tabCount: 12) == 9) // 19 doesn't exist
        #expect(chord.press(digit: 0, tabCount: 12) == nil) // 90 doesn't either
        #expect(chord.press(digit: 2, tabCount: 12) == 2)
    }

    @Test
    func releasing_command_ends_the_run() {
        var chord = TabIndexChord()
        #expect(chord.press(digit: 1, tabCount: 12) == 1)
        chord.reset()
        #expect(chord.press(digit: 2, tabCount: 12) == 2)
    }

    @Test
    func an_idle_gap_ends_the_run() {
        var chord = TabIndexChord()
        let start = Date()
        #expect(chord.press(digit: 1, tabCount: 12, now: start) == 1)
        let later = start.addingTimeInterval(TabIndexChord.window + 0.5)
        #expect(chord.press(digit: 2, tabCount: 12, now: later) == 2)
    }

    @Test
    func digits_inside_the_window_still_join() {
        var chord = TabIndexChord()
        let start = Date()
        #expect(chord.press(digit: 1, tabCount: 12, now: start) == 1)
        let soon = start.addingTimeInterval(TabIndexChord.window / 2)
        #expect(chord.press(digit: 2, tabCount: 12, now: soon) == 12)
    }
}
