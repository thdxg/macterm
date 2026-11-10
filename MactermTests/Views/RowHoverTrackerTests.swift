import AppKit
@testable import Macterm
import Testing

/// The self-heal of `RowHoverTracker` must find the pointer inside only over
/// the tracker's own area. A view that does not clip to its bounds has a
/// visible rect as large as the visible part of its ancestors, and a check
/// against that rect revealed the control of every row (the Keymaps clear
/// badges after a recording).
@MainActor
struct RowHoverTrackerTests {
    private func trackerInWindow() -> (NSWindow, RowHoverTracker.TrackerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let tracker = RowHoverTracker.TrackerView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
        window.contentView?.addSubview(tracker)
        return (window, tracker)
    }

    @Test
    func pointer_on_the_tracker_is_inside() {
        let (window, tracker) = trackerInWindow()
        #expect(tracker.contains(windowPoint: NSPoint(x: 50, y: 20)))
        withExtendedLifetime(window) {}
    }

    @Test
    func pointer_elsewhere_in_the_window_is_outside() {
        let (window, tracker) = trackerInWindow()
        #expect(!tracker.contains(windowPoint: NSPoint(x: 300, y: 250)))
        #expect(tracker.visibleRect == tracker.bounds)
        withExtendedLifetime(window) {}
    }

    @Test
    func row_that_moved_away_from_the_pointer_is_outside() {
        let (window, tracker) = trackerInWindow()
        tracker.frame.origin.y = 200
        #expect(!tracker.contains(windowPoint: NSPoint(x: 50, y: 20)))
        withExtendedLifetime(window) {}
    }
}
