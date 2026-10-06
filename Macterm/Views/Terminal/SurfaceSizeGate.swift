import Foundation

/// Decides whether a view size may reach `ghostty_surface_set_size`.
///
/// A terminal pane can be laid out at a degenerate size for a moment — a
/// split animation's first frame, a tiling window manager re-tiling the
/// window, a container collapsing during a tab switch — or for real, when
/// the window is dragged small enough that the sidebar leaves the pane a
/// few columns. Either way, once libghostty is told the grid is two cells
/// wide it reflows every line into two-column fragments, and growing back
/// does not undo that: the content lands above the viewport and the pane
/// shows a blank screen with a fresh prompt. Ghostty.app never meets this
/// because its window cannot get that small; ours can, so the gate lives
/// here rather than in a window minimum.
///
/// Below the threshold the surface simply keeps its last grid and renders
/// clipped, which is what the user would expect of a pane a few pixels
/// wide, and the content is intact when the pane is sized again.
enum SurfaceSizeGate {
    /// The smallest grid worth reflowing into. A pane a user can still read
    /// is wider than this; a pane narrower than this is mid-layout or a
    /// sliver, and its content must not be reflowed for it.
    static let minimumColumns: UInt32 = 8
    static let minimumRows: UInt32 = 2

    /// What the gate judges a size against: the surface's cell size and its
    /// chrome, the pixels that hold no cells (see `chrome`).
    struct Metrics {
        var cellWidthPx: UInt32
        var cellHeightPx: UInt32
        var chromeWidthPx: UInt32
        var chromeHeightPx: UInt32
    }

    /// Whether a backing-pixel size may be applied to a surface measuring
    /// `metrics`. Zero cell metrics (the surface has not measured its font
    /// yet) admit every non-empty size, since the grid cannot be judged; an
    /// empty size never passes.
    ///
    /// The grid is counted inside the chrome. Counting the whole size let a
    /// split peeling open from its seam through at one row: Macterm's 16pt
    /// `window-padding-y` is more than a cell, so a pane two cells tall is a
    /// one-row grid. Born at that size, a new pane's zmx client printed
    /// `session "…" created` and a newline, which scrolled the line into
    /// scrollback where the client's `ESC[2J` can't reach it, and growing the
    /// pane pulled it back down above the prompt.
    static func admits(widthPx: UInt32, heightPx: UInt32, metrics: Metrics) -> Bool {
        guard widthPx > 0, heightPx > 0 else { return false }
        guard metrics.cellWidthPx > 0, metrics.cellHeightPx > 0 else { return true }
        let columns = widthPx.subtractingClamped(metrics.chromeWidthPx) / metrics.cellWidthPx
        let rows = heightPx.subtractingClamped(metrics.chromeHeightPx) / metrics.cellHeightPx
        return columns >= minimumColumns && rows >= minimumRows
    }

    /// The pixels along one axis of a surface's current size that hold no
    /// cells: `window-padding` plus the leftover under a cell. libghostty
    /// doesn't report its padding, so this stands in for it — overstating it
    /// by under a cell, which only makes the gate refuse a size slightly
    /// sooner.
    static func chrome(totalPx: UInt32, cells: UInt16, cellPx: UInt32) -> UInt32 {
        totalPx.subtractingClamped(UInt32(cells) * cellPx)
    }
}

private extension UInt32 {
    func subtractingClamped(_ other: UInt32) -> UInt32 {
        self > other ? self - other : 0
    }
}
