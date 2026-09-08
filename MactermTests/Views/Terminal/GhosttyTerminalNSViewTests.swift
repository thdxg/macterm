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

    // MARK: - Context-menu scroll navigation

    private typealias Snapshot = GhosttyTerminalNSView.ScrollbarSnapshot

    @Test
    func scrollNavigation_disablesBothActionsWithoutScrollbackGeometry() {
        // Alt screen (total == len) and a snapshot whose viewport is larger than
        // the buffer both mean "no scrollback"; neither may underflow.
        for snapshot in [Snapshot(total: 24, offset: 0, len: 24), Snapshot(total: 24, offset: 10, len: 30)] {
            #expect(!snapshot.hasScrollback)
            #expect(snapshot.maxScrollableRow == 0)
            #expect(!snapshot.canScrollUp)
            #expect(!snapshot.canScrollDown)
        }
    }

    @Test
    func scrollNavigation_enablesOnlyAvailableDirectionsAtTheBoundaries() {
        let top = Snapshot(total: 100, offset: 0, len: 24)
        #expect(top.maxScrollableRow == 76)
        #expect(!top.canScrollUp)
        #expect(top.canScrollDown)

        let bottom = Snapshot(total: 100, offset: 76, len: 24)
        #expect(bottom.canScrollUp)
        #expect(!bottom.canScrollDown)
    }

    @Test
    func scrollNavigation_enablesBothActionsBetweenTheBoundaries() {
        let middle = Snapshot(total: 100, offset: 32, len: 24)
        #expect(middle.canScrollUp)
        #expect(middle.canScrollDown)
    }

    // MARK: - IME composition state

    private func makeView() -> GhosttyTerminalNSView {
        GhosttyTerminalNSView(
            paneID: UUID(),
            workingDirectory: "/tmp",
            sessionName: "marked-text-test"
        )
    }

    /// The mirror has to track AppKit's calls even with no surface attached —
    /// it used to be gated on one, so a composition begun before the surface
    /// existed read as not-composing.
    @Test
    func markedText_tracksCompositionWithoutASurface() {
        let view = makeView()
        #expect(!view.hasMarkedText())

        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
    }

    /// `unmarkText` was gated on a surface too — the damaging direction, since
    /// a stranded range makes `keyDown` drop every unmodified key.
    @Test
    func markedText_unmarkClearsWithoutASurface() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.unmarkText()

        #expect(!view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: NSNotFound, length: 0))
    }

    /// An empty commit is how some input sources abandon a composition, and it
    /// bailed out ahead of the clear.
    @Test
    func markedText_emptyCommitEndsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(!view.hasMarkedText())
    }

    /// Focus leaving mid-composition is the path with no AppKit guarantee of an
    /// `unmarkText`, and the one that left a pane unable to type.
    @Test
    func markedText_focusLossAbandonsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        _ = view.resignFirstResponder()

        #expect(!view.hasMarkedText())
    }

    /// A destroyed surface has nowhere to commit, so the preedit must not
    /// outlive it into a reattached surface.
    @Test
    func markedText_surfaceTeardownAbandonsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.destroySurface()

        #expect(!view.hasMarkedText())
    }
}
