@testable import Macterm
import Testing

/// The gate in front of `ghostty_surface_set_size`: a degenerate grid must
/// never reach libghostty, because reflowing into it scrolls the pane's
/// content out of the viewport for good.
struct SurfaceSizeGateTests {
    /// A 16×40 px cell is what a Retina 2x pane measures at the default font.
    private let cell: (w: UInt32, h: UInt32) = (16, 40)

    @Test
    func a_readable_grid_is_admitted() {
        // 75 columns × 78 rows: an ordinary half-width pane.
        #expect(SurfaceSizeGate.admits(widthPx: 1200, heightPx: 3120, cellWidthPx: cell.w, cellHeightPx: cell.h))
        // Exactly the minimum passes.
        #expect(SurfaceSizeGate.admits(
            widthPx: SurfaceSizeGate.minimumColumns * cell.w,
            heightPx: SurfaceSizeGate.minimumRows * cell.h,
            cellWidthPx: cell.w, cellHeightPx: cell.h
        ))
    }

    @Test
    func a_degenerate_grid_is_refused() {
        // The measured failure: a 2×2 grid left behind by a window shrunk
        // to the sidebar's width.
        #expect(!SurfaceSizeGate.admits(widthPx: 2 * cell.w, heightPx: 2 * cell.h, cellWidthPx: cell.w, cellHeightPx: cell.h))
        // One dimension short is enough to refuse.
        #expect(!SurfaceSizeGate.admits(widthPx: 2000, heightPx: cell.h, cellWidthPx: cell.w, cellHeightPx: cell.h))
        #expect(!SurfaceSizeGate.admits(widthPx: 3 * cell.w, heightPx: 3000, cellWidthPx: cell.w, cellHeightPx: cell.h))
        // A fraction of a cell short of the minimum rounds down and refuses.
        #expect(!SurfaceSizeGate.admits(
            widthPx: SurfaceSizeGate.minimumColumns * cell.w - 1,
            heightPx: 3000, cellWidthPx: cell.w, cellHeightPx: cell.h
        ))
    }

    @Test
    func unmeasured_cells_admit_any_nonempty_size_and_never_an_empty_one() {
        // Before the surface has measured its font the grid can't be judged,
        // so the size goes through — the surface needs one to start at all.
        #expect(SurfaceSizeGate.admits(widthPx: 10, heightPx: 10, cellWidthPx: 0, cellHeightPx: 0))
        #expect(!SurfaceSizeGate.admits(widthPx: 0, heightPx: 10, cellWidthPx: 0, cellHeightPx: 0))
        #expect(!SurfaceSizeGate.admits(widthPx: 10, heightPx: 0, cellWidthPx: cell.w, cellHeightPx: cell.h))
    }
}
