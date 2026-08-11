import AppKit
@testable import Macterm
import Testing

/// Guards the terminal-window identity cache (`AppDelegate.mainWindow`).
///
/// The pointer is "the first window to become main", observed via
/// `didBecomeMainNotification`. The observation must be live from
/// `applicationWillFinishLaunching`: on a LaunchServices launch (Dock,
/// Finder, `open`) the window becomes main BEFORE
/// `applicationDidFinishLaunching` runs, so an observer installed there
/// missed it — the cache stayed nil until the user mained some other window
/// (typically Settings), which then got adopted as "the terminal window".
/// Every hotkey gate misfired (Cmd+W closed the window, Cmd+D went dead) and
/// `reopenIfNeeded` re-fronted the hidden Settings window on each refocus.
@MainActor
struct AppDelegateTests {
    /// Windows that can become main need a title bar; keep them off-screen
    /// and never ordered in so the test run shows nothing.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test
    func first_window_to_become_main_is_cached_from_willFinishLaunching() {
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        let terminal = makeWindow()
        let settings = makeWindow()

        // The launch-time didBecomeMain — on a LaunchServices launch this
        // arrives before applicationDidFinishLaunching ever runs.
        NotificationCenter.default.post(
            name: NSWindow.didBecomeMainNotification, object: terminal
        )
        #expect(delegate.mainWindow === terminal)

        // A later window becoming main (Settings) must never displace it.
        NotificationCenter.default.post(
            name: NSWindow.didBecomeMainNotification, object: settings
        )
        #expect(delegate.mainWindow === terminal)
    }

    /// Issue #241: a launch that never brings the app to the front (how macOS
    /// relaunches apps for "Reopen windows when logging back in") skips
    /// AppKit's open-untitled step, so SwiftUI never builds the `WindowGroup`
    /// window — leaving a running app with no window and no way back to one.
    @Test
    func launch_asks_swiftui_for_a_window_when_the_launch_produced_none() {
        let delegate = AppDelegate()
        var requests = 0
        delegate.windowLister = { [] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.repairMissingWindow(attempt: AppDelegate.windowRepairAttempts)

        #expect(requests == 1)
    }

    /// The repair must stay a repair: a normal launch already has its window,
    /// and asking again would open a second one in a single-window app.
    @Test
    func launch_leaves_an_existing_window_alone() {
        let delegate = AppDelegate()
        var requests = 0
        let existing = makeWindow()
        delegate.windowLister = { [existing] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.repairMissingWindow(attempt: AppDelegate.windowRepairAttempts)

        #expect(requests == 0)
    }

    /// SwiftUI's window appears a run-loop turn or two after the request, so
    /// two callers racing (the launch repair and an activation landing just
    /// before it) must not each open one.
    @Test
    func window_requests_are_debounced() {
        let delegate = AppDelegate()
        var requests = 0
        delegate.windowLister = { [] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.repairMissingWindow(attempt: AppDelegate.windowRepairAttempts)
        delegate.showWindow()

        #expect(requests == 1)
    }
}
