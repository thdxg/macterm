import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: appBundleID, category: "ExplainOutput")

/// Explain Output: what the pane gives the on-device model, and where the
/// popover points. The rules for the text are in `OutputExplanation`.
extension GhosttyTerminalNSView {
    /// Explain the selection or, with none, the output of the last command,
    /// in a popover at `point` (the right click). Else the popover goes
    /// above a selection, and below the output, at the prompt, so it does not
    /// cover the text it explains.
    ///
    /// With no selection, Explain first selects the output, so the user sees
    /// what it explains (`selectLastCommandOutput`). The selection goes when
    /// the popover closes, if it is still the one that Explain made.
    func explainOutput(at point: NSPoint? = nil) {
        // A selection that the last Explain made is not the user's.
        explainPopover.dropOnClose()
        let language = OnDeviceModel.replyLanguage
        let active = readText(area: GHOSTTY_POINT_ACTIVE) ?? ""
        let guess = OutputExplanation.lastCommand(in: active)
        let explanation: OutputExplanation
        var textAnchor: NSRect?
        var edge = NSRectEdge.minY
        var onClose: (() -> Void)?
        if let selection = selectedText() {
            explanation = OutputExplanation(source: .selection, text: selection, replyLanguage: language)
            textAnchor = selectionAnchorRect()
            if textAnchor != nil { edge = .maxY }
        } else if selectLastCommandOutput(rowsUp: guess.map { [$0.linesBelowOutput] } ?? [1, 2, 3]),
                  let output = selectedText()
        {
            // The selection says where the output starts, so the whole
            // command is above it, also on more than one line. A long output
            // pushes the command into the scrollback.
            let command = OutputExplanation.command(in: active, before: output)
                ?? readText(area: GHOSTTY_POINT_SCREEN).flatMap { OutputExplanation.command(in: $0, before: output) }
                ?? guess?.command
            logger.debug("explain output: command of \(command.map { $0.split(separator: "\n").count } ?? 0, privacy: .public) lines")
            explanation = OutputExplanation(source: .output, command: command, text: output, replyLanguage: language)
            onClose = { [weak self] in
                guard let self, selectedText() == output else { return }
                sendBindingAction("clear_selection")
            }
        } else {
            explanation = guessedLastCommandExplanation(language: language)
        }
        if point != nil { edge = .minY }
        let anchor = point.map { NSRect(x: $0.x, y: $0.y, width: 1, height: 1) }
            ?? textAnchor
            ?? cursorCellRect()
            ?? NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        logger.debug("explain \(explanation.source.rawValue, privacy: .public) at \(NSStringFromRect(anchor), privacy: .public)")
        explainPopover.show(explanation, anchor: anchor, edge: edge, in: self, onClose: onClose)
    }

    /// Select the output of the last command with ghostty's own gesture: a
    /// ⌘-triple-click on a line of output selects all of that command's
    /// output, from the shell integration's OSC 133 marks
    /// (`Screen.selectOutput`; ⌃ on Linux, ⌘ on macOS).
    ///
    /// A ⌘-click also opens a link. libghostty decides "over a link" only on
    /// a pointer move, with that move's modifiers, so the move here carries
    /// none and arms no link; only the presses carry ⌘. A last move with no
    /// modifiers resets them, so ⌘ does not stay down for link highlights.
    ///
    /// The click goes to the last line of output, `rowsUp` rows above the
    /// cursor, as the text guess counts them (`LastCommand.linesBelowOutput`).
    /// With no guess, the rows above the cursor are tried in turn. The guess
    /// is what makes the right row: nushell marks its prompt rows as
    /// output, so a click on a prompt row selects that row. Without shell
    /// integration a triple-click selects one line, which is not taken. At
    /// a shell prompt no program captures the mouse, so the clicks reach no
    /// program.
    private func selectLastCommandOutput(rowsUp candidates: [Int]) -> Bool {
        guard let surface, let cursor = cursorCellRect() else { return false }
        // The IME point's y, from the top of the view (the coordinates of
        // `ghostty_surface_mouse_pos`), is the bottom edge of the cursor's
        // row, so row `n` above the cursor has its middle at n + 0.5 rows.
        let cursorBottom = bounds.height - cursor.maxY
        defer { restorePointerPosition() }
        for rowsUp in candidates {
            let y = cursorBottom - (CGFloat(rowsUp) + 0.5) * cursor.height
            guard y > 0 else { break }
            ghostty_surface_mouse_pos(surface, 1, y, GHOSTTY_MODS_NONE)
            for _ in 0 ..< 3 {
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)
            }
            ghostty_surface_mouse_pos(surface, 1, y, GHOSTTY_MODS_NONE)
            if ghostty_surface_has_selection(surface) { return true }
        }
        return false
    }

    /// Tell libghostty where the real pointer is again, after the clicks of
    /// `selectLastCommandOutput`, so hover (links, the pointer shape) is
    /// right before the next mouse move.
    private func restorePointerPosition() {
        guard let surface, let window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(local) {
            ghostty_surface_mouse_pos(surface, local.x, bounds.height - local.y, GHOSTTY_MODS_NONE)
        } else {
            ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE)
        }
    }

    /// The output of the last command without shell integration: the guess
    /// of `OutputExplanation.lastCommand(in:)` on the active screen, then on
    /// the whole scrollback (a long output), else the end of the screen.
    private func guessedLastCommandExplanation(language: String?) -> OutputExplanation {
        let active = readText(area: GHOSTTY_POINT_ACTIVE) ?? ""
        if let found = OutputExplanation.lastCommand(in: active)
            ?? readText(area: GHOSTTY_POINT_SCREEN).flatMap(OutputExplanation.lastCommand(in:))
        {
            return OutputExplanation(source: .output, command: found.command, text: found.output, replyLanguage: language)
        }
        return OutputExplanation(source: .output, text: OutputExplanation.screenWithoutPrompt(active), replyLanguage: language)
    }

    /// The first cell of the selection, in view coordinates. libghostty
    /// reports its position in points from the top of the surface, at the
    /// bottom edge of the cell, as the IME point is; the cell height comes
    /// from the IME point. nil when that cell is not in view (a selection
    /// that starts in the scrollback).
    private func selectionAnchorRect() -> NSRect? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let height = cursorCellRect()?.height ?? 16
        let rect = NSRect(x: text.tl_px_x, y: bounds.height - text.tl_px_y, width: 1, height: height)
        return bounds.contains(rect) ? rect : nil
    }
}
