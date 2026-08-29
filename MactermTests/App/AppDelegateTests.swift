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

    // MARK: - The surface incubator's window is not a terminal window

    /// `SurfaceIncubator` parks off-screen panes in a plain, permanently
    /// invisible `NSWindow` so their surfaces can be created before the tab is
    /// ever viewed. It lives in `NSApp.windows` and is not an `NSPanel`, which
    /// is precisely the shape the window heuristics used to read as "the
    /// ordered-out terminal window".
    private func makeIncubatorWindow() -> NSWindow {
        let window = SurfaceIncubatorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// A launch that produced no window but has already warmed a pane must
    /// still ask SwiftUI for one — counting the incubator as "a window exists"
    /// would disable the #241 repair on exactly the app it is meant to save.
    @Test
    func launch_repair_does_not_count_the_incubator_window() {
        let delegate = AppDelegate()
        var requests = 0
        let incubator = makeIncubatorWindow()
        delegate.windowLister = { [incubator] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.repairMissingWindow(attempt: AppDelegate.windowRepairAttempts)

        #expect(requests == 1)
    }

    /// "Show Window" must never front the incubator: it is a blank black
    /// 1024×768 rectangle, and it is not what the user asked to see.
    @Test
    func show_window_never_fronts_the_incubator_window() {
        let delegate = AppDelegate()
        var requests = 0
        let incubator = makeIncubatorWindow()
        delegate.windowLister = { [incubator] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.showWindow()

        #expect(requests == 1)
        #expect(!incubator.isVisible)
    }

    /// The activation re-front must not adopt the incubator either. Its
    /// fallback looks for a hidden non-panel window, and the incubator is
    /// permanently hidden — so it would match on every activation, order in a
    /// black rectangle, and cache it as `mainWindow`, which is the pointer
    /// every key-window-gated hotkey reads.
    @Test
    func reopen_never_adopts_the_incubator_window() {
        let delegate = AppDelegate()
        var requests = 0
        let incubator = makeIncubatorWindow()
        delegate.windowLister = { [incubator] }
        delegate.openInitialWindow = { requests += 1 }

        delegate.reopenIfNeeded()

        #expect(delegate.mainWindow == nil)
        #expect(!incubator.isVisible)
        // Nothing frontable was found, so this activation is treated as the
        // user asking for the window that never got built.
        #expect(requests == 1)
    }

    /// The exclusion is the incubator only — the heuristic still has to accept
    /// an ordinary hidden window, or the #241 repair would fire on an app that
    /// already has one and open a second.
    @Test
    func an_ordinary_hidden_window_is_still_a_terminal_window_candidate() {
        #expect(AppDelegate.isTerminalWindowCandidate(makeWindow()))
        #expect(!AppDelegate.isTerminalWindowCandidate(makeIncubatorWindow()))
        #expect(!AppDelegate.isTerminalWindowCandidate(NSPanel()))
    }
}
