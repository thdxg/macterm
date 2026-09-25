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

    // MARK: - Progress report routing

    /// ERROR reaches the finish callback flagged as a failure; REMOVE and
    /// PAUSE (both `.ended`) reach it as a success.
    @Test
    func progressReport_routesToStartAndFinishWithTheOutcome() {
        let view = GhosttyTerminalNSView(
            paneID: UUID(),
            workingDirectory: "/tmp",
            sessionName: "progress-test"
        )
        var events: [String] = []
        view.onProgressStarted = { events.append("started") }
        view.onProgressFinished = { failed in events.append(failed ? "failed" : "finished") }

        view.surfaceDidReportProgress(.running)
        view.surfaceDidReportProgress(.failed)
        view.surfaceDidReportProgress(.ended)

        #expect(events == ["started", "failed", "finished"])
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

    // MARK: - Command chords under a non-Latin layout

    /// Whether ghostty's default keybinds claim ⌘ on `keyCode`, sent the way
    /// `performKeyEquivalent` sends it: super, the layout's own key as the
    /// unshifted codepoint, and `text` as the key's text. Run against ghostty's
    /// real defaults, so a GhosttyKit bump that changes how a binding is found
    /// fails here rather than in a Ukrainian user's hands.
    private func defaultKeybindsClaimCommand(keyCode: UInt32, unshifted: Unicode.Scalar, text: String?) throws -> Bool {
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var ke = ghostty_input_key_s()
        ke.action = GHOSTTY_ACTION_PRESS
        ke.keycode = keyCode
        ke.mods = GHOSTTY_MODS_SUPER
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.unshifted_codepoint = unshifted.value
        guard let text else { return ghostty_config_key_is_binding(config, ke) }
        return text.withCString { ptr in
            ke.text = ptr
            return ghostty_config_key_is_binding(config, ke)
        }
    }

    /// Under a Ukrainian layout the C and V keys type `с` and `м`, which is all
    /// libghostty had to go on — and `super+c`/`super+v` are unicode `c`/`v`,
    /// so copy and paste never fired. The Command map's letter as the key's
    /// text is what reaches them (`HotkeyRegistry.commandKeyCharacter`).
    @Test
    func commandChord_onACyrillicKey_reachesCopyAndPasteOnlyThroughItsText() throws {
        #expect(try !defaultKeybindsClaimCommand(keyCode: 8, unshifted: "\u{0441}", text: nil))
        #expect(try !defaultKeybindsClaimCommand(keyCode: 9, unshifted: "\u{043C}", text: nil))
        #expect(try defaultKeybindsClaimCommand(keyCode: 8, unshifted: "\u{0441}", text: "c"))
        #expect(try defaultKeybindsClaimCommand(keyCode: 9, unshifted: "\u{043C}", text: "v"))
        // The same chord under a US layout needs no text at all.
        #expect(try defaultKeybindsClaimCommand(keyCode: 8, unshifted: "c", text: nil))
    }

    /// The flip side, and why `isAppShortcut` names its system keys by
    /// `eventToken`: with `q` as the text, ghostty's own `super+q=quit` claims
    /// ⌘Q under a Cyrillic layout — an action Macterm leaves unhandled, so the
    /// menu bar's Quit must get the chord first.
    @Test
    func commandQ_onACyrillicKey_isGhosttysQuitOnceItCarriesItsText() throws {
        #expect(try defaultKeybindsClaimCommand(keyCode: 12, unshifted: "\u{0439}", text: "q"))
    }
}
