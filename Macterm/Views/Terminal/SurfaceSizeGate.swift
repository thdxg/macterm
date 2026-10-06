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

    /// Whether a backing-pixel size may be applied to a surface whose cells
    /// measure `cellWidthPx` × `cellHeightPx`. Zero cell metrics (the surface
    /// has not measured its font yet) admit every non-empty size, since the
    /// grid cannot be judged; an empty size never passes.
    static func admits(widthPx: UInt32, heightPx: UInt32, cellWidthPx: UInt32, cellHeightPx: UInt32) -> Bool {
        guard widthPx > 0, heightPx > 0 else { return false }
        guard cellWidthPx > 0, cellHeightPx > 0 else { return true }
        return widthPx / cellWidthPx >= minimumColumns && heightPx / cellHeightPx >= minimumRows
    }
}
