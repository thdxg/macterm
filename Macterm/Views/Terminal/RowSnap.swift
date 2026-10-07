import CoreGraphics
import Foundation

/// Settles the sub-row remainder a smooth-scroll gesture leaves behind onto
/// the nearest whole row (Settings → Animations → Snap to whole row).
///
/// Remainders are the core's own (`ScrollAccumulator.pending`): backing
/// pixels, positive is content moved down. The snap eases the remainder from
/// where the gesture left it to `0` or to a whole cell either way; landing on
/// a cell is the core committing one row with nothing left over, which is
/// why the last frame aims a pixel past it (`landingOvershoot`) and then
/// back to zero — aiming at the cell exactly can come up a rounding error
/// short and leave the grid a hair off its rows.
struct RowSnap: Equatable {
    /// Long enough to read as a settle, short enough that the next gesture
    /// rarely interrupts it.
    static let duration: TimeInterval = 0.15

    /// How far past the row the landing frame aims, in backing pixels.
    static let landingOvershoot: CGFloat = 1

    let from: CGFloat
    let to: CGFloat

    /// Nil when there is nothing to settle: no cell yet, or a remainder
    /// already on a row.
    init?(pending: CGFloat, cellHeight: CGFloat) {
        guard cellHeight > 0 else { return nil }
        let nearest: CGFloat = if abs(pending) * 2 < cellHeight {
            0
        } else {
            pending < 0 ? -cellHeight : cellHeight
        }
        guard abs(nearest - pending) > 0.001 else { return nil }
        from = pending
        to = nearest
    }

    func isFinished(at elapsed: TimeInterval) -> Bool {
        elapsed >= Self.duration
    }

    /// The remainders to aim the accumulator at, in order, on a frame drawn
    /// `elapsed` into the snap: one eased value while it runs (ease-out
    /// cubic, so it leaves at the gesture's speed and slows onto the row),
    /// and the landing once it is over.
    func targets(at elapsed: TimeInterval) -> [CGFloat] {
        guard !isFinished(at: elapsed) else {
            guard to != 0 else { return [0] }
            return [to + (to < 0 ? -Self.landingOvershoot : Self.landingOvershoot), 0]
        }
        let t = max(elapsed, 0) / Self.duration
        let eased = 1 - pow(1 - t, 3)
        return [from + (to - from) * CGFloat(eased)]
    }
}
