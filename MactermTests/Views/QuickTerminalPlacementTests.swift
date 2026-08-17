import AppKit
@testable import Macterm
import Testing

/// Frame math for showing the quick-terminal panel: centered by default,
/// restored from the persisted drag position when one exists, and always
/// landing fully inside the screen's visible frame.
@MainActor
struct QuickTerminalPlacementTests {
    /// Deliberately offset from the origin so a bug that drops the visible
    /// frame's own minX/minY (a menu bar, a Dock) can't pass as centered math.
    private let screen = NSRect(x: 100, y: 50, width: 1000, height: 800)

    @Test
    func no_stored_position_centers_the_panel() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: nil
        )
        #expect(frame.size == CGSize(width: 500, height: 400))
        #expect(frame.origin == CGPoint(x: 350, y: 250))
    }

    @Test
    func stored_position_restores_the_origin_within_the_spare_room() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: CGPoint(x: 0.25, y: 1.0)
        )
        // Spare room is 500×400: x sits a quarter along, y flush with the top.
        #expect(frame.origin == CGPoint(x: 225, y: 450))
        #expect(frame.maxY == screen.maxY)
    }

    /// A panel dragged partly off-screen (or a stale value from a smaller
    /// screen) must reopen fully visible, not restore the out-of-range spot.
    @Test
    func out_of_range_position_clamps_fully_on_screen() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: CGPoint(x: -0.4, y: 1.7)
        )
        #expect(frame.minX == screen.minX)
        #expect(frame.maxY == screen.maxY)
        #expect(screen.contains(frame))
    }

    @Test
    func full_size_panel_centers_regardless_of_position() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 1.0,
            heightFraction: 1.0,
            position: CGPoint(x: 0.9, y: 0.1)
        )
        #expect(frame == screen)
    }

    @Test
    func position_round_trips_through_frame() {
        let stored = CGPoint(x: 0.25, y: 0.75)
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: stored
        )
        #expect(QuickTerminalPlacement.position(of: frame, in: screen) == stored)
    }

    /// The save side clamps too: a frame the window server let escape the
    /// visible frame (drags can leave partially off-screen windows) persists
    /// as an on-screen fraction rather than an out-of-range one.
    @Test
    func position_of_an_off_screen_frame_clamps_to_the_edge() {
        let offLeft = NSRect(x: screen.minX - 300, y: screen.minY + 100, width: 500, height: 400)
        let position = QuickTerminalPlacement.position(of: offLeft, in: screen)
        #expect(position.x == 0)
        #expect(position.y == 0.25)
    }

    /// No spare room on an axis (panel as large as the screen) has no
    /// meaningful fraction — it reads as centered instead of dividing by zero.
    @Test
    func position_of_a_full_size_panel_reads_centered() {
        let full = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height)
        #expect(QuickTerminalPlacement.position(of: full, in: screen) == CGPoint(x: 0.5, y: 0.5))
    }
}
