import AppKit
import GhosttyKit
@testable import Macterm
import Testing

/// Covers the terminal NSView contracts that do not require a live surface.
@MainActor
struct GhosttyTerminalNSViewTests {
    @Test
    func terminalSurface_exposesGhosttyAccessibilityContract() {
        let view = GhosttyTerminalNSView(
            paneID: UUID(),
            workingDirectory: "/tmp",
            sessionName: "accessibility-test"
        )

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityHelp() == "Terminal content area")
        #expect((view.accessibilityValue() as? String)?.isEmpty == true)
        #expect(view.accessibilitySelectedTextRange() == NSRange())
        #expect(view.accessibilitySelectedText() == nil)
        #expect(view.accessibilityNumberOfCharacters() == 0)
        #expect(view.accessibilityVisibleCharacterRange() == NSRange())
        #expect(view.accessibilityLine(for: 0) == 0)
        #expect(view.accessibilityString(for: NSRange())?.isEmpty == true)
        #expect(view.accessibilityAttributedString(for: NSRange()) == nil)
    }

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
