import CoreGraphics
@testable import Macterm
import Testing

/// Pure row↔pixel conversion used by `SurfaceScrollView` to bridge libghostty's
/// row-based scrollback geometry (Y-down) and AppKit's point-based clip view
/// (Y-up). UI behavior isn't unit-tested per the project's conventions, but
/// this inversion is the one piece of error-prone pure logic.
struct SurfaceScrollGeometryTests {
    private let cell: CGFloat = 20

    // MARK: - documentHeight

    @Test
    func document_height_is_total_rows_times_cell() {
        // 100 rows of scrollback at 20pt cells.
        #expect(SurfaceScrollView.documentHeight(total: 100, cellHeight: cell, viewportHeight: 480) == 2000)
    }

    @Test
    func document_height_never_below_viewport() {
        // No scrollback (total == visible rows): document can't be shorter than
        // what's on screen, or there'd be a phantom scroll region.
        #expect(SurfaceScrollView.documentHeight(total: 24, cellHeight: cell, viewportHeight: 600) == 600)
    }

    // MARK: - documentOffsetY (core → clip view)

    @Test
    func offset_at_bottom_is_zero() {
        // Viewport pinned to the bottom of history: offset = total - len.
        // total 100, len 24, offset 76 → 0 rows below → y == 0.
        #expect(SurfaceScrollView.documentOffsetY(total: 100, offset: 76, len: 24, cellHeight: cell) == 0)
    }

    @Test
    func offset_at_top_is_full_scrollback() {
        // Scrolled to the very top: offset 0. Rows below = 100 - 0 - 24 = 76.
        #expect(SurfaceScrollView.documentOffsetY(total: 100, offset: 0, len: 24, cellHeight: cell) == 76 * cell)
    }

    @Test
    func offset_in_middle() {
        // offset 40 → rows below = 100 - 40 - 24 = 36.
        #expect(SurfaceScrollView.documentOffsetY(total: 100, offset: 40, len: 24, cellHeight: cell) == 36 * cell)
    }

    @Test
    func offset_never_negative() {
        // Degenerate geometry (len momentarily exceeds remaining rows) clamps.
        #expect(SurfaceScrollView.documentOffsetY(total: 24, offset: 10, len: 24, cellHeight: cell) == 0)
    }

    // MARK: - rowFromOffset (clip view → core), inverse of documentOffsetY

    @Test
    func row_at_bottom_is_total_minus_len() {
        // documentHeight 2000, visible height 480 (24 rows), clip at bottom
        // (originY 0) → top visible row = (2000 - 0 - 480) / 20 = 76.
        let row = SurfaceScrollView.rowFromOffset(
            visibleOriginY: 0, visibleHeight: 480, documentHeight: 2000, cellHeight: cell
        )
        #expect(row == 76)
    }

    @Test
    func row_at_top_is_zero() {
        // Clip scrolled to the document top: originY = docHeight - visibleHeight.
        let row = SurfaceScrollView.rowFromOffset(
            visibleOriginY: 1520, visibleHeight: 480, documentHeight: 2000, cellHeight: cell
        )
        #expect(row == 0)
    }

    @Test
    func row_round_trips_with_offset() {
        // For a given core offset, documentOffsetY → rowFromOffset recovers it.
        let total: UInt64 = 100, len: UInt64 = 24, offset: UInt64 = 40
        let docHeight = SurfaceScrollView.documentHeight(total: total, cellHeight: cell, viewportHeight: CGFloat(len) * cell)
        let y = SurfaceScrollView.documentOffsetY(total: total, offset: offset, len: len, cellHeight: cell)
        let row = SurfaceScrollView.rowFromOffset(
            visibleOriginY: y, visibleHeight: CGFloat(len) * cell, documentHeight: docHeight, cellHeight: cell
        )
        #expect(row == Int(offset))
    }

    @Test
    func row_from_fractional_offset_uses_whole_lines() {
        // Scroller drags can land between cells, but the terminal core is
        // row-based, so fractional offsets choose the containing whole row.
        let row = SurfaceScrollView.rowFromOffset(
            visibleOriginY: 9, visibleHeight: 480, documentHeight: 2000, cellHeight: cell
        )
        #expect(row == 75)
    }

    @Test
    func row_never_negative() {
        let row = SurfaceScrollView.rowFromOffset(
            visibleOriginY: 9999, visibleHeight: 480, documentHeight: 2000, cellHeight: cell
        )
        #expect(row == 0)
    }
}
