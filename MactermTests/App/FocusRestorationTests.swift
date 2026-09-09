import AppKit
@testable import Macterm
import Testing

/// The two entry points differ in what a missing window MEANS, and the
/// difference is the whole bug behind #377.
@MainActor
struct FocusRestorationTests {
    private func makePane() -> Pane {
        Pane(projectPath: NSTemporaryDirectory(), projectID: UUID())
    }

    /// An offscreen window that can take first responder. Released by the test
    /// (`isReleasedWhenClosed` off, so ARC owns it).
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func settle(_ isDone: () -> Bool) async {
        for _ in 0 ..< 100 where !isDone() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The regression: `makeNSView` asks for focus a run-loop tick after
    /// building the view, and SwiftUI has often not added the host to the
    /// window by then. Resolving the window lazily is what lets the restore
    /// wait for it — the pane is focused the moment its view lands, with no
    /// click.
    @Test
    func restoring_when_attached_waits_for_the_view_to_reach_a_window() async {
        let pane = makePane()
        let view = pane.ensureNSView()
        let window = makeWindow()

        // Asked for while the view is in no window at all, exactly as the
        // representable asks for it.
        #expect(view.window == nil)
        FocusRestoration.restoreFocusWhenAttached(to: pane.id, finder: { pane })

        window.contentView?.addSubview(view)
        await settle { window.firstResponder === view }
        #expect(window.firstResponder === view)
    }

    /// The counterpart contract: a caller that names the window itself means
    /// "no target" by nil, and must not be handed whatever window turns up
    /// later.
    @Test
    func restoring_into_a_named_window_does_not_retry_when_there_is_none() async {
        let pane = makePane()
        let view = pane.ensureNSView()
        let window = makeWindow()

        FocusRestoration.restoreFocus(to: pane.id, finder: { pane }, in: nil)

        window.contentView?.addSubview(view)
        await settle { window.firstResponder === view }
        #expect(window.firstResponder !== view)
    }
}
