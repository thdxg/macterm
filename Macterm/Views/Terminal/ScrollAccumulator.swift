import CoreGraphics

/// Macterm's copy of libghostty's per-surface scroll accumulator
/// (`Surface.mouse.pending_scroll_y`): the sub-row remainder of every scroll
/// delta the core has been handed, in backing pixels.
///
/// The core keeps that remainder and, with `smooth-scroll` on, publishes it
/// as the viewport's sub-row offset — which is what makes trackpad
/// scrollback move by pixels. It is not readable back over the C API, and
/// **nothing else writes it**: `scrollCallback` is the only producer, and
/// Macterm is the only caller of `ghostty_surface_mouse_scroll`. So mirroring
/// every delta we send reproduces it exactly, which is what lets
/// `SurfaceScrollView` aim a scroller drag at a specific sub-row offset
/// (`nudge(toward:cellHeight:)`) instead of only at a whole row.
///
/// A row-level move made any other way (`scroll_to_row`, program output)
/// zeroes the core's *published offset* but not this accumulator, so the
/// mirror stays true across them. The consequence of being wrong is bounded
/// and cosmetic: the offset lands up to a row out and the next drag update
/// corrects it.
struct ScrollAccumulator: Equatable {
    /// The remainder the core is holding, in backing pixels. Always within
    /// one cell of zero once `advance` has run.
    private(set) var pending: CGFloat = 0

    /// Feed the core's own arithmetic: whole rows commit and leave the
    /// remainder behind. `pixels` is the delta *after* the multiplier the
    /// core applies (`Surface.scrollCallback`'s `yoff_adjusted`), and
    /// `cellHeight` is the cell height in backing pixels, the units the core
    /// compares against. Returns the rows it committed, positive up.
    @discardableResult
    mutating func advance(pixels: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        let combined = pending + pixels
        guard abs(combined) >= cellHeight else {
            pending = combined
            return 0
        }
        // Rounds toward zero, as ghostty's `@trunc` does.
        let rows = (combined / cellHeight).rounded(.towardZero)
        pending = combined - rows * cellHeight
        return Int(rows)
    }

    /// The delta to send so the core ends up holding exactly `remainder`
    /// (backing pixels, within one cell of zero), before the multiplier it
    /// will apply. Sending it commits no row: the sum lands on `remainder`,
    /// which is under a cell by construction.
    func nudge(toward remainder: CGFloat, multiplier: Double) -> CGFloat {
        guard multiplier != 0 else { return 0 }
        return (remainder - pending) / CGFloat(multiplier)
    }
}
