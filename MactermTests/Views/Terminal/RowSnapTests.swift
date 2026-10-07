import CoreGraphics
@testable import Macterm
import Testing

/// The settle that puts a smooth-scroll gesture's leftover onto a row. Each
/// target is aimed through `ScrollAccumulator`, exactly as the view does, so
/// these check what the core ends up holding, not just the curve.
struct RowSnapTests {
    private let cell: CGFloat = 40

    /// Aim `acc` at every target of a frame; the rows the core committed.
    private func land(_ snap: RowSnap, at elapsed: TimeInterval, on acc: inout ScrollAccumulator) -> Int {
        snap.targets(at: elapsed).reduce(0) { rows, target in
            rows + acc.advance(pixels: acc.nudge(toward: target, multiplier: 1), cellHeight: cell)
        }
    }

    @Test
    func under_half_a_row_settles_back_to_the_row_it_left() {
        let snap = RowSnap(pending: 15, cellHeight: cell)
        #expect(snap?.to == 0)
        #expect(RowSnap(pending: -15, cellHeight: cell)?.to == 0)
    }

    @Test
    func past_half_a_row_settles_onto_the_next_row_either_way() {
        #expect(RowSnap(pending: 25, cellHeight: cell)?.to == cell)
        #expect(RowSnap(pending: -25, cellHeight: cell)?.to == -cell)
    }

    @Test
    func a_remainder_already_on_a_row_needs_no_snap() {
        #expect(RowSnap(pending: 0, cellHeight: cell) == nil)
        #expect(RowSnap(pending: 10, cellHeight: 0) == nil)
    }

    @Test
    func the_settle_eases_monotonically_and_commits_nothing_on_the_way() {
        guard let snap = RowSnap(pending: 30, cellHeight: cell) else {
            Issue.record("expected a snap")
            return
        }
        var acc = ScrollAccumulator()
        acc.advance(pixels: 30, cellHeight: cell)
        var last = acc.pending
        for frame in 1 ..< 9 {
            let elapsed = Double(frame) / 60
            #expect(land(snap, at: elapsed, on: &acc) == 0)
            #expect(acc.pending >= last)
            #expect(acc.pending < cell)
            last = acc.pending
        }
    }

    @Test
    func landing_on_the_next_row_commits_exactly_one_and_leaves_nothing() {
        for pending: CGFloat in [25, 33.3, -21.7, -39.9] {
            guard let snap = RowSnap(pending: pending, cellHeight: cell) else {
                Issue.record("expected a snap for \(pending)")
                continue
            }
            var acc = ScrollAccumulator()
            acc.advance(pixels: pending, cellHeight: cell)
            let rows = land(snap, at: RowSnap.duration, on: &acc)
            #expect(rows == (pending < 0 ? -1 : 1))
            #expect(abs(acc.pending) < 0.0001)
        }
    }

    @Test
    func landing_back_on_its_own_row_commits_nothing() {
        guard let snap = RowSnap(pending: -12, cellHeight: cell) else {
            Issue.record("expected a snap")
            return
        }
        var acc = ScrollAccumulator()
        acc.advance(pixels: -12, cellHeight: cell)
        #expect(land(snap, at: RowSnap.duration, on: &acc) == 0)
        #expect(acc.pending == 0)
    }
}
