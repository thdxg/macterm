import CoreGraphics
@testable import Macterm
import Testing

/// Macterm's mirror of libghostty's scroll accumulator, and the nudge that
/// aims it at a chosen sub-row offset (`SurfaceScrollView`'s scroller drag).
/// The arithmetic has to match `Surface.scrollCallback` exactly, since
/// nothing can read the core's copy back.
struct ScrollAccumulatorTests {
    private let cell: CGFloat = 40

    @Test
    func under_a_cell_nothing_commits_and_the_remainder_is_kept() {
        var acc = ScrollAccumulator()
        #expect(acc.advance(pixels: 12, cellHeight: cell) == 0)
        #expect(acc.pending == 12)
        #expect(acc.advance(pixels: 12, cellHeight: cell) == 0)
        #expect(acc.pending == 24)
    }

    @Test
    func whole_rows_commit_and_leave_the_remainder_behind() {
        var acc = ScrollAccumulator()
        #expect(acc.advance(pixels: 95, cellHeight: cell) == 2)
        #expect(acc.pending == 15)
        // Downward, rounding toward zero as ghostty's @trunc does: -75 is
        // one whole row and a remainder, not two.
        #expect(acc.advance(pixels: -90, cellHeight: cell) == -1)
        #expect(acc.pending == -35)
    }

    @Test
    func a_zero_cell_height_is_inert() {
        var acc = ScrollAccumulator()
        #expect(acc.advance(pixels: 100, cellHeight: 0) == 0)
        #expect(acc.pending == 0)
    }

    /// The nudge is the delta that lands the core's accumulator on the
    /// wanted remainder — and, since both ends are within a cell, it can
    /// never carry a row with it.
    @Test
    func the_nudge_lands_on_the_target_without_committing_a_row() {
        var acc = ScrollAccumulator()
        acc.advance(pixels: 30, cellHeight: cell)
        let delta = acc.nudge(toward: -10, multiplier: 1)
        #expect(delta == -40)
        #expect(acc.advance(pixels: delta, cellHeight: cell) == 0)
        #expect(acc.pending == -10)
    }

    @Test
    func the_nudge_divides_out_the_multiplier_the_core_will_apply() {
        var acc = ScrollAccumulator()
        let multiplier = 2.5
        let delta = acc.nudge(toward: -25, multiplier: multiplier)
        #expect(delta == -10)
        // What the core adds is the delta times its own multiplier.
        #expect(acc.advance(pixels: delta * CGFloat(multiplier), cellHeight: cell) == 0)
        #expect(acc.pending == -25)
    }

    @Test
    func a_zero_multiplier_asks_for_nothing() {
        #expect(ScrollAccumulator().nudge(toward: -10, multiplier: 0) == 0)
    }
}
