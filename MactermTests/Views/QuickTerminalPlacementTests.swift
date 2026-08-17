import AppKit
@testable import Macterm
import Testing

/// Frame math for showing the quick-terminal panel: centered by default,
/// restored from the persisted drag position when one exists — faithfully,
/// including a panel the user left partly off-screen — and clamped only as
/// far as keeping enough of the panel on screen to grab it again.
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

    /// The user dragged the panel partway off the left edge; the restore puts
    /// it back exactly there, not snapped inside the visible frame.
    @Test
    func partly_off_screen_position_restores_faithfully() {
        let stored = CGPoint(x: -0.4, y: 0.5)
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: stored
        )
        // Origin 200pt past the left edge — 300pt of the panel still visible.
        #expect(frame.minX == screen.minX - 200)
        #expect(QuickTerminalPlacement.position(of: frame, in: screen) == stored)
    }

    /// A stale value (from a bigger screen, or a corrupt write) can't strand
    /// the panel: each axis keeps `minVisible` points reachable, and the top
    /// edge — where the grab handle is — never lands above the visible frame.
    @Test
    func stale_position_clamps_to_stay_grabbable() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: CGPoint(x: -10, y: 3)
        )
        #expect(frame.maxX == screen.minX + QuickTerminalPlacement.minVisible)
        #expect(frame.maxY == screen.maxY)
    }

    @Test
    func stale_position_past_the_bottom_keeps_the_handle_reachable() {
        let frame = QuickTerminalPlacement.frame(
            visibleFrame: screen,
            widthFraction: 0.5,
            heightFraction: 0.5,
            position: CGPoint(x: 0.5, y: -10)
        )
        #expect(frame.maxY == screen.minY + QuickTerminalPlacement.minVisible)
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

    /// The save side is deliberately unclamped: an overhanging placement is
    /// the user's, so it persists as the out-of-0…1 fraction that reproduces
    /// it, not snapped to an edge.
    @Test
    func position_of_an_off_screen_frame_saves_the_overhang() {
        let offLeft = NSRect(x: screen.minX - 300, y: screen.minY + 100, width: 500, height: 400)
        let position = QuickTerminalPlacement.position(of: offLeft, in: screen)
        #expect(position.x == -0.6)
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
