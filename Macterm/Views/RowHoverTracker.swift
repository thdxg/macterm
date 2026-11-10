import AppKit
import SwiftUI

/// Reports pointer enter/exit for the view it backs, through an AppKit
/// tracking area rather than SwiftUI's `.onHover` — see
/// `SidebarProjectHeader` for why that distinction matters, and
/// `PaneDragDrop.DragSourceView` for the same pattern over a pane.
///
/// The self-heal in `updateTrackingAreas` is the part worth keeping: a row
/// that reshapes, scrolls out of view, or loses its window mid-hover never
/// receives its exit event, and a hover-revealed control that misses one
/// stays lit on the wrong row for the rest of the session.
struct RowHoverTracker: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context _: Context) -> TrackerView {
        let view = TrackerView()
        configure(view)
        return view
    }

    func updateNSView(_ view: TrackerView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: TrackerView) {
        view.onHoverChanged = { hovering in isHovered = hovering }
    }

    final class TrackerView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var isInside = false

        /// Transparent to the mouse: the row beneath owns every click, drag,
        /// scroll and right-click. Tracking-area enter/exit is dispatched by
        /// geometry and is unaffected by this.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            installTrackingArea(assumingInside: pointerIsInside)
            // Re-derive the truth on every layout pass, rather than trusting
            // that an exit event arrived. Deferred because this runs inside
            // AppKit's layout, and the report writes SwiftUI state.
            Task { @MainActor [weak self] in
                self?.syncWithPointer()
            }
        }

        /// Reports where the pointer is now, and puts a new tracking area
        /// that starts from the same answer. AppKit keeps its own inside
        /// state for each area and sends an exit only for an area that it
        /// thinks the pointer is in. When this report says inside and the
        /// area does not agree (the row moved under the pointer between the
        /// area and the report, as when a recorded keybind adds a conflict
        /// line), no exit comes, and the control stays revealed after the
        /// pointer leaves.
        func syncWithPointer() {
            let inside = pointerIsInside
            installTrackingArea(assumingInside: inside)
            report(inside)
        }

        private func installTrackingArea(assumingInside inside: Bool) {
            trackingAreas.forEach { removeTrackingArea($0) }
            // `.activeInActiveApp` means a BACKGROUND Macterm reveals
            // nothing on hover — deliberate, and the same choice
            // `PaneDragDrop` makes: an inactive window should not offer a
            // one-click action the user can trip over on their way to
            // focusing it. `.inVisibleRect` keeps the area matched to the
            // row as the List scrolls without a callback per frame.
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
            // The next event is then the exit, whatever AppKit saw last.
            if inside { options.insert(.assumeInside) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { report(false) }
        }

        override func mouseEntered(with _: NSEvent) {
            report(true)
        }

        override func mouseExited(with _: NSEvent) {
            report(false)
        }

        /// The pointer in window coordinates, or nil while the app is not
        /// active. The tests replace it.
        var pointerLocation: (NSWindow) -> NSPoint? = { window in
            NSApp.isActive ? window.mouseLocationOutsideOfEventStream : nil
        }

        /// Where the pointer actually is, asked of the window rather than
        /// inferred from the last event we happened to receive.
        private var pointerIsInside: Bool {
            guard let window, let inWindow = pointerLocation(window) else { return false }
            return visibleRect.contains(convert(inWindow, from: nil))
        }

        private func report(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onHoverChanged?(inside)
        }
    }
}
