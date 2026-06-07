import AppKit

/// Starts a pane's shell process *before* its tab is ever viewed.
///
/// A pane's shell spawns only when its `GhosttyTerminalNSView.createSurface()`
/// succeeds, which needs the view to be in a window with a non-zero size. SwiftUI
/// only renders the active tab, so non-active tabs' views never attach to a
/// window and their shells never start until the tab is first viewed.
///
/// The incubator is a single never-shown `NSWindow` that gives those off-screen
/// panes a real window + size, so `createSurface()` succeeds and the shell runs.
/// Surface *creation* is enough to start the process — rendering stays lazy. When
/// the tab is finally viewed, SwiftUI adopts the same pane-owned scroll view; the
/// `TerminalSurface` representable removes it from the incubator first (a view
/// can't live in two superviews), and the already-created surface is reused.
@MainActor
final class SurfaceIncubator {
    static let shared = SurfaceIncubator()

    private lazy var window: NSWindow = {
        // Borderless, never ordered on-screen. A generous size so the warmed
        // surface's backing buffer is non-trivial; the real size is applied when
        // the view moves to the visible window.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.orderOut(nil)
        return win
    }()

    private init() {}

    /// Start `pane`'s surface (and thus its shell) off-screen if it isn't running
    /// yet. Idempotent: a no-op once the surface exists. The pane's scroll view is
    /// parked in the incubator window only long enough for `createSurface()` to
    /// succeed; `TerminalSurface.makeNSView` pulls it back out when the tab is
    /// viewed.
    func warm(_ pane: Pane) {
        guard pane.nsView?.surface == nil else { return }
        let scroll = pane.ensureScrollView()
        guard let content = window.contentView else { return }
        scroll.frame = content.bounds
        content.addSubview(scroll)
        scroll.layoutSubtreeIfNeeded()
        // Wire the title callback so the off-screen shell's OSC-2 title updates
        // reach `pane.title` (and thus the tab name) before the tab is ever
        // viewed. The rest of the callbacks are UI-coupled and are wired by
        // `TerminalSurface.configure` when SwiftUI adopts the view; `configure`
        // re-sets `onTitleChange` to the same effect, so this isn't clobbered in
        // a way that matters. (`currentPwd` is set directly by the callback
        // dispatcher, so it already works off-screen.)
        pane.nsView?.onTitleChange = { [weak pane] title in pane?.title = title }
        pane.nsView?.createSurface()
    }
}
