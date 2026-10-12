import AppKit

/// Decides whether a surface's pixels count as on screen — the bool that
/// `ghostty_surface_set_occlusion` receives.
///
/// The window's `occlusionState` is the normal source. But AppKit computes it
/// late: a window that has just opened is on screen (`isVisible`) for some
/// hundred milliseconds before its first `didChangeOcclusionState` arrives,
/// and until then the state does not contain `.visible`. Taken at face value,
/// that told every pane of a launching window that it was occluded. The
/// renderer then parked before it drew a frame, and the layer showed a
/// buffer that nothing had drawn — rows of colored blocks and no text — until
/// the next resize forced a draw. Ghostty.app does not meet this: its
/// surfaces start visible, and it reports occlusion only from the
/// notification.
///
/// So a window that has not reported its occlusion yet is judged by
/// `isVisible` alone. Its first report replaces that guess, and from then on
/// the reported state is the only source, so a covered window still parks
/// its renderers.
enum SurfaceVisibility {
    static func isVisible(
        rendersForPreview: Bool,
        hiddenInLayout: Bool,
        windowIsVisible: Bool,
        windowReportsVisible: Bool,
        windowHasReportedOcclusion: Bool
    ) -> Bool {
        if rendersForPreview { return true }
        if hiddenInLayout { return false }
        if windowHasReportedOcclusion { return windowReportsVisible }
        return windowReportsVisible || windowIsVisible
    }
}

/// The windows that have posted `didChangeOcclusionState` at least once, so
/// their `occlusionState` is real (see `SurfaceVisibility`).
///
/// Weak keys: a closed window drops out by itself. The app-wide observer
/// starts before any window opens (`AppDelegate.applicationWillFinishLaunching`).
/// A window that reported before it started counts as not reported, which
/// costs only an occluded window drawing until its next report — never a
/// visible pane that stays blank.
@MainActor
enum WindowOcclusionReports {
    private static let reported = NSHashTable<NSWindow>.weakObjects()
    private static var observer: NSObjectProtocol?

    static func startTracking() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { noteReport(from: window) }
            }
        }
    }

    /// Record that `window` has reported its occlusion. A view's own observer
    /// calls this too, before it reads the state: the order in which two
    /// observers of one notification run is not defined.
    static func noteReport(from window: NSWindow) {
        reported.add(window)
    }

    static func hasReported(_ window: NSWindow) -> Bool {
        reported.contains(window)
    }
}
