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
/// prompt, but every widget is an ordinary on-screen window whose bounds the
/// window list reports without any permission — enough to find each group's
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
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        var hostPIDs: [pid_t: Bool] = [:]
        return list.compactMap { info in
            // Desktop-level windows only: Notification Center's own panel
            // sits above the normal level and isn't a widget.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < normalLevel,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
            else { return nil }
            let isHost = hostPIDs[pid] ?? {
                let host = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == hostBundleID
                hostPIDs[pid] = host
                return host
            }()
            guard isHost else { return nil }
            // The window list is top-left based on the primary display.
            let window = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            let widget = window.insetBy(dx: windowInset, dy: windowInset)
            return widget.width > 0 && widget.height > 0 ? widget : nil
        }
    }
}
