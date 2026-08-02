import AppKit
import GhosttyKit
@testable import Macterm
import Testing

/// Covers the pure libghostty-enum mappings on the terminal NSView. The view
/// itself (surface lifecycle, rendering) is deliberately not unit-tested.
@MainActor
struct GhosttyTerminalNSViewTests {
    @Test
    func cursorMapping_coversTheShapesGhosttyEmits() {
        // The shapes the core actually sends over a terminal: text grid,
        // links, and TUI drag affordances.
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) == NSCursor.iBeam)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) == NSCursor.pointingHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) == NSCursor.arrow)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRAB) == NSCursor.openHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRABBING) == NSCursor.closedHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_CROSSHAIR) == NSCursor.crosshair)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED) == NSCursor.operationNotAllowed)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NS_RESIZE) != nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE) != nil)
    }

    @Test
    func cursorMapping_ignoresShapesWithNoMacOSCounterpart() {
        // Unknown → nil keeps the previous cursor, mirroring Ghostty.app.
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_ZOOM_IN) == nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_WAIT) == nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_PROGRESS) == nil)
    }
}
