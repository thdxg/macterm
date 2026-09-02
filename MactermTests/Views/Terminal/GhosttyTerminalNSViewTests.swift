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

    // MARK: - Scrollback provenance

    @Test
    func scrollbarSnapshot_marksOnlyRowsBeforeTheLiveBottomAsHistory() {
        let history = GhosttyTerminalNSView.ScrollbarSnapshot(total: 100, offset: 30, len: 40)
        let bottom = GhosttyTerminalNSView.ScrollbarSnapshot(total: 100, offset: 60, len: 40)
        let alternateScreen = GhosttyTerminalNSView.ScrollbarSnapshot(total: 40, offset: 0, len: 40)

        #expect(history.isViewingHistory)
        #expect(!bottom.isViewingHistory)
        #expect(!alternateScreen.isViewingHistory)
    }

    @Test
    func scrollbarSnapshot_handlesOutOfRangeOffsetsWithoutOverflow() {
        let snapshot = GhosttyTerminalNSView.ScrollbarSnapshot(
            total: UInt64.max,
            offset: UInt64.max,
            len: 1
        )

        #expect(!snapshot.isViewingHistory)
    }

    @Test
    func historicalViewport_isAViewerTransformationWithoutASelection() {
        let view = makeView()

        view.surfaceDidUpdateScrollbar(total: 100, offset: 30, len: 40)
        #expect(view.hasViewerTransformation)

        view.surfaceDidUpdateScrollbar(total: 100, offset: 60, len: 40)
        #expect(!view.hasViewerTransformation)
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
