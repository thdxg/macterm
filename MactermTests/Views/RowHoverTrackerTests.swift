import AppKit
@testable import Macterm
import Testing

/// The self-heal of `RowHoverTracker` reports the pointer as inside only
/// over the tracker's own area. A view that does not clip to its bounds has
/// a visible rect as large as its window, and a check against that rect
/// alone revealed the control of every row (the Keymaps clear badges after a
/// recording).
@MainActor
struct RowHoverTrackerTests {
    @MainActor
    private final class Harness {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let tracker = RowHoverTracker.TrackerView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
        var pointer: NSPoint?
        var reports: [Bool] = []

        init() {
            window.contentView?.addSubview(tracker)
            tracker.pointerLocation = { [weak self] _ in self?.pointer }
            tracker.onHoverChanged = { [weak self] in self?.reports.append($0) }
        }
    }

    @Test
    func pointer_on_the_tracker_reports_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.reportPointer()
        #expect(harness.reports == [true])
    }

    @Test
    func pointer_elsewhere_in_the_window_reports_no_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.reportPointer()
        harness.pointer = NSPoint(x: 300, y: 250)
        harness.tracker.reportPointer()
        #expect(harness.reports == [true, false])
    }

    @Test
    func row_that_moved_away_from_the_pointer_reports_no_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.reportPointer()
        harness.tracker.frame.origin.y = 200
        harness.tracker.reportPointer()
        #expect(harness.reports == [true, false])
    }

    @Test
    func inactive_app_reports_no_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.reportPointer()
        harness.pointer = nil
        harness.tracker.reportPointer()
        #expect(harness.reports == [true, false])
    }
}
