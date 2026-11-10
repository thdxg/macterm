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

        override init(frame: NSRect) {
            super.init(frame: frame)
            // A view that does not clip to its bounds (the default since the
            // macOS 14 SDK) has a visible rect as large as the visible part
            // of its ancestors. The self-heal and the `.inVisibleRect` area
            // read that rect, so without the clip each layout pass revealed
            // the control of every row while the pointer was anywhere in
            // the list (the Keymaps clear badges after a recording).
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Transparent to the mouse: the row beneath owns every click, drag,
        /// scroll and right-click. Tracking-area enter/exit is dispatched by
        /// geometry and is unaffected by this.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            // `.activeInActiveApp` means a BACKGROUND Macterm reveals
            // nothing on hover — deliberate, and the same choice
            // `PaneDragDrop` makes: an inactive window should not offer a
            // one-click action the user can trip over on their way to
            // focusing it. `.inVisibleRect` keeps the area matched to the
            // row as the List scrolls without a callback per frame.
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
            // Re-derive the truth on every layout pass, rather than trusting
            // that an exit event arrived. Deferred because this runs inside
            // AppKit's layout, and the report writes SwiftUI state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                report(pointerIsInside)
            }
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

        /// Where the pointer actually is, asked of the window rather than
        /// inferred from the last event we happened to receive.
        private var pointerIsInside: Bool {
            guard let window, NSApp.isActive else { return false }
            return contains(windowPoint: window.mouseLocationOutsideOfEventStream)
        }

        func contains(windowPoint: NSPoint) -> Bool {
            visibleRect.contains(convert(windowPoint, from: nil))
        }

        private func report(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            onHoverChanged?(inside)
        }
    }
}
