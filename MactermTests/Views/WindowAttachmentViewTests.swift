import AppKit
@testable import Macterm
import Testing

/// A window's views find their window when AppKit attaches them, however late
/// that is (`WindowAttachmentView`).
@MainActor
struct WindowAttachmentViewTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Runs the main queue until `condition` holds, or fails after `timeout`.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test
    func a_view_attached_long_after_it_was_made_reports_its_window() async {
        // The old poll stopped after 30 main-queue turns, so a view that
        // waited this long for its window never styled or registered it.
        let view = WindowAttachmentView()
        var attached: [NSWindow] = []
        view.onAttach = { attached.append($0) }
        for _ in 0 ..< 100 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(attached.isEmpty)

        let window = makeWindow()
        window.contentView?.addSubview(view)
        await waitUntil { !attached.isEmpty }
        #expect(attached.count == 1)
        #expect(attached.first === window)
    }

    @Test
    func a_view_reports_only_its_first_window() async {
        let view = WindowAttachmentView()
        var attached: [NSWindow] = []
        view.onAttach = { attached.append($0) }

        let first = makeWindow()
        first.contentView?.addSubview(view)
        await waitUntil { attached.count == 1 }
        view.removeFromSuperview()
        makeWindow().contentView?.addSubview(view)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(attached.count == 1)
        #expect(attached.first === first)
    }
}
