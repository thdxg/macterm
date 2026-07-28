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
}
