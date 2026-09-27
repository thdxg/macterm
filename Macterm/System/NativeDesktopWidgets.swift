import AppKit
import CoreGraphics

/// Where the system's own desktop widgets are, so Macterm's can line up with
/// them.
///
/// macOS lays desktop widgets out in GROUPS, each with its own origin — not
/// on one screen-wide grid. Notification Center (which hosts them) logs its
/// placement store as `groups: [{origin: (18.0, 25.0), items: [<col: 0,
/// row: 0, size: medium>, …]}]`, and items inside a group sit on a 180pt
/// lattice (a 164pt cell plus a 16pt gap). That store lives in Notification
/// Center's own container, which another app can't read without a privacy
/// prompt, but every widget is an ordinary window whose bounds the window
/// list reports without any permission — enough to find each group's
/// lattice. `DesktopWidgetGrid` snaps onto the lattice of whatever widget is
/// nearby.
enum NativeDesktopWidgets {
    static let hostBundleID = "com.apple.notificationcenterui"

    /// A widget's window is the widget plus 8pt on every side for its
    /// shadow: 360×180 for a 344×164 medium widget (measured on macOS 27).
    static let windowInset: CGFloat = 8

    /// The system widgets' frames in AppKit's global (bottom-left) space.
    @MainActor
    static func frames() -> [CGRect] {
        // Every window, not only the on-screen ones: Notification Center
        // reports its widgets as off screen whenever windows cover the
        // desktop (measured), which is exactly when a widget is created from
        // Settings or restored at launch — reading on-screen windows only saw
        // no system widgets then, and placed ours over them.
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        var hostPIDs: [pid_t: Bool] = [:]
        return widgetFrames(in: list, primaryScreenHeight: primaryHeight) { pid in
            if let known = hostPIDs[pid] { return known }
            let host = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == hostBundleID
            hostPIDs[pid] = host
            return host
        }
    }

    /// The level a system desktop widget's window sits at: two above the
    /// Finder's desktop icons (measured). Notification Center keeps other
    /// windows one level lower — see `widgetFrames`.
    static let widgetLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2

    /// The widgets among `windows` (window-list entries), converted from the
    /// window list's top-left space to AppKit's. Pure, for tests.
    ///
    /// Notification Center's windows at the desktop are not all widgets. It
    /// also keeps an untitled, fully transparent window a level below them
    /// (measured: 464×824, alpha 0, left behind after widgets were dragged
    /// and resized), and taking that one for a widget both blocked the empty
    /// cells it covered and pulled Macterm's widgets onto its lattice. So a
    /// widget is a window of the host at `widgetLevel`, with visible alpha,
    /// whose every side is a whole number of cells — a widget window is
    /// 180pt per cell each way, its 8pt shadow insets included.
    static func widgetFrames(
        in windows: [[String: Any]],
        primaryScreenHeight: CGFloat,
        isHost: (pid_t) -> Bool
    ) -> [CGRect] {
        windows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == widgetLevel,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  isWholeCells(width), isWholeCells(height),
                  isHost(pid)
            else { return nil }
            let window = CGRect(x: x, y: primaryScreenHeight - y - height, width: width, height: height)
            return window.insetBy(dx: windowInset, dy: windowInset)
        }
    }

    /// Whether a widget window's side spans a whole number of cells.
    private static func isWholeCells(_ length: CGFloat) -> Bool {
        let cells = (length / DesktopWidgetGrid.pitch).rounded()
        return cells >= 1 && abs(length - cells * DesktopWidgetGrid.pitch) <= 1
    }
}
