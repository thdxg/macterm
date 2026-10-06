@testable import Macterm
import Testing

/// The gate in front of `ghostty_surface_set_size`: a degenerate grid must
/// never reach libghostty, because reflowing into it scrolls the pane's
/// content out of the viewport for good.
struct SurfaceSizeGateTests {
    /// A 16×40 px cell is what a Retina 2x pane measures at the default font.
    private let cell: (w: UInt32, h: UInt32) = (16, 40)

    private func metrics(chrome: UInt32 = 0) -> SurfaceSizeGate.Metrics {
        .init(cellWidthPx: cell.w, cellHeightPx: cell.h, chromeWidthPx: chrome, chromeHeightPx: chrome)
    }

    @Test
    func a_readable_grid_is_admitted() {
        // 75 columns × 78 rows: an ordinary half-width pane.
        #expect(SurfaceSizeGate.admits(widthPx: 1200, heightPx: 3120, metrics: metrics()))
        // Exactly the minimum passes.
        #expect(SurfaceSizeGate.admits(
            widthPx: SurfaceSizeGate.minimumColumns * cell.w,
            heightPx: SurfaceSizeGate.minimumRows * cell.h,
            metrics: metrics()
        ))
    }

    @Test
    func a_degenerate_grid_is_refused() {
        // The measured failure: a 2×2 grid left behind by a window shrunk
        // to the sidebar's width.
        #expect(!SurfaceSizeGate.admits(widthPx: 2 * cell.w, heightPx: 2 * cell.h, metrics: metrics()))
        // One dimension short is enough to refuse.
        #expect(!SurfaceSizeGate.admits(widthPx: 2000, heightPx: cell.h, metrics: metrics()))
        #expect(!SurfaceSizeGate.admits(widthPx: 3 * cell.w, heightPx: 3000, metrics: metrics()))
        // A fraction of a cell short of the minimum rounds down and refuses.
        #expect(!SurfaceSizeGate.admits(
            widthPx: SurfaceSizeGate.minimumColumns * cell.w - 1,
            heightPx: 3000,
            metrics: metrics()
        ))
    }

    @Test
    func the_grid_is_counted_inside_the_padding() {
        // The measured failure: Macterm's 16pt `window-padding-y` is 64px of
        // a Retina pane's height, so a split peeling open at two cells' height
        // was a one-row grid, and a new pane's zmx `session "…" created` line
        // scrolled out of reach of the client's clear.
        let padding: UInt32 = 64
        #expect(!SurfaceSizeGate.admits(
            widthPx: 2000, heightPx: SurfaceSizeGate.minimumRows * cell.h + padding - 1,
            metrics: metrics(chrome: padding)
        ))
        #expect(SurfaceSizeGate.admits(
            widthPx: 2000, heightPx: SurfaceSizeGate.minimumRows * cell.h + padding,
            metrics: metrics(chrome: padding)
        ))
        #expect(!SurfaceSizeGate.admits(
            widthPx: SurfaceSizeGate.minimumColumns * cell.w + padding - 1, heightPx: 3000,
            metrics: metrics(chrome: padding)
        ))
        // Chrome larger than the whole size is no grid at all.
        #expect(!SurfaceSizeGate.admits(widthPx: 50, heightPx: 50, metrics: metrics(chrome: padding)))
    }

    @Test
    func chrome_is_what_the_current_grid_leaves_over() {
        // 1271px over 63 cells of 19px: 74px of padding and leftover.
        #expect(SurfaceSizeGate.chrome(totalPx: 1271, cells: 63, cellPx: 19) == 74)
        // A grid libghostty clamped up past the size reads as no chrome.
        #expect(SurfaceSizeGate.chrome(totalPx: 30, cells: 1, cellPx: 42) == 0)
    }

    @Test
    func unmeasured_cells_admit_any_nonempty_size_and_never_an_empty_one() {
        // Before the surface has measured its font the grid can't be judged,
        // so the size goes through — the surface needs one to start at all.
        let unmeasured = SurfaceSizeGate.Metrics(cellWidthPx: 0, cellHeightPx: 0, chromeWidthPx: 0, chromeHeightPx: 0)
        #expect(SurfaceSizeGate.admits(widthPx: 10, heightPx: 10, metrics: unmeasured))
        #expect(!SurfaceSizeGate.admits(widthPx: 0, heightPx: 10, metrics: unmeasured))
        #expect(!SurfaceSizeGate.admits(widthPx: 10, heightPx: 0, metrics: metrics()))
    }
}
