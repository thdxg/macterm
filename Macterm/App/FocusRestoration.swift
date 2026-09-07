import AppKit
import Foundation

/// Centralizes focus-restoration timing. Several code paths need to hand first
/// responder to a terminal NSView *after* some AppKit/SwiftUI state has settled
/// (command palette close, pane close + tree reshape, quick terminal show, tab
/// switch). The common failure mode is calling `makeFirstResponder` before the
/// NSView has been attached to a window or the new pane's NSView has been
/// materialized by SwiftUI. This helper retries on the run loop until the view
/// is in a window, with a bounded attempt cap so we never spin forever.
@MainActor
enum FocusRestoration {
    /// Max retries (each at `retryInterval`) before giving up. 40 * 50ms = 2s —
    /// long enough for any SwiftUI/AppKit churn we've observed.
    private static let maxAttempts = 40
    private static let retryInterval: TimeInterval = 0.05

    /// Set while a sidebar row's inline rename field is open (see
    /// `SidebarPresentationState.beginRename`).
    ///
    /// Restoration is a *retry loop*, so it can land long after the call that
    /// started it. Double-clicking an inactive tab's title both switches tabs
    /// and opens the rename field in one gesture: the newly activated pane
    /// transitions to focused, `TerminalSurface.updateNSView` asks for
    /// restoration, and — when that pane's view isn't in the window yet (an
    /// unloaded project, a pinned tab rebuilt from its declaration) — the
    /// retry resolves several ticks later and takes first responder back off
    /// the caret. The field stays on screen while the keystrokes go to the
    /// shell. Rename commit and cancel both call `restoreFocusToActivePane()`,
    /// so the terminal gets focus the moment editing ends.
    static var isEditingInlineName = false

    /// Restore first responder to the pane's NSView inside `window`. If the
    /// view isn't in `window` yet (tree reshape, split tear-down), retry on the
    /// main run loop until it is or we hit the attempt cap. Safe to call from
    /// any pane-close / tab-switch / palette-dismiss path.
    static func restoreFocus(to paneID: UUID, finder: @escaping () -> Pane?, in window: NSWindow?) {
        guard let window else { return }
        restoreFocus(to: paneID, finder: finder, in: window, attempt: 0)
    }

    /// Convenience: look up the pane via a SplitNode tree.
    static func restoreFocus(to paneID: UUID, in tree: SplitNode, window: NSWindow?) {
        restoreFocus(to: paneID, finder: { tree.findPane(id: paneID) }, in: window)
    }

    private static func restoreFocus(
        to paneID: UUID,
        finder: @escaping () -> Pane?,
        in window: NSWindow,
        attempt: Int
    ) {
        // Paired conditions on purpose: the flag alone would wedge terminal
        // focus app-wide if a rename ever ended without clearing it (its row
        // closing mid-edit, say), and the field-editor check alone would break
        // the search bar, which restores focus *out* of its own text field.
        if isEditingInlineName, (window.firstResponder as? NSTextView)?.isFieldEditor == true {
            return
        }
        if let pane = finder(), let view = pane.nsView, view.window === window {
            window.makeFirstResponder(view)
            view.notifySurfaceFocused()
            return
        }
        guard attempt < maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            restoreFocus(to: paneID, finder: finder, in: window, attempt: attempt + 1)
        }
    }
}
