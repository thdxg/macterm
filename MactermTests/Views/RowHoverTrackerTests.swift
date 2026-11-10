import AppKit
@testable import Macterm
import Testing

/// The tracker's report and its tracking area must start from the same
/// answer. AppKit sends an exit only for an area that it thinks the pointer
/// is in, so a report of "inside" over an area that thinks "outside" never
/// gets its exit, and the control stays revealed (the Keymaps clear badge
/// after a recording).
@MainActor
struct RowHoverTrackerTests {
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
            tracker.pointerLocation = { [unowned self] _ in pointer }
            tracker.onHoverChanged = { [unowned self] in reports.append($0) }
        }

        var areaAssumesInside: Bool {
            tracker.trackingAreas.first?.options.contains(.assumeInside) ?? false
        }
    }

    @Test
    func pointer_inside_reports_hover_and_the_area_waits_for_the_exit() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.syncWithPointer()
        #expect(harness.reports == [true])
        #expect(harness.tracker.trackingAreas.count == 1)
        #expect(harness.areaAssumesInside)
    }

    @Test
    func pointer_that_left_while_the_row_moved_clears_the_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.syncWithPointer()
        // The row moves away under a pointer that does not move.
        harness.tracker.frame.origin.y = 200
        harness.tracker.syncWithPointer()
        #expect(harness.reports == [true, false])
        #expect(harness.tracker.trackingAreas.count == 1)
        #expect(!harness.areaAssumesInside)
    }

    @Test
    func inactive_app_reports_no_hover() {
        let harness = Harness()
        harness.pointer = NSPoint(x: 50, y: 20)
        harness.tracker.syncWithPointer()
        harness.pointer = nil
        harness.tracker.syncWithPointer()
        #expect(harness.reports == [true, false])
        #expect(!harness.areaAssumesInside)
    }
}
