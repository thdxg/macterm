import AppKit
import SwiftUI

/// Recursively renders a split tree as nested split views or a single terminal pane.
struct SplitTreeView: View {
    let node: SplitNode
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
    let isActiveProject: Bool
    let projectID: UUID
    let isSplit: Bool
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onClosePane: (UUID) -> Void
    let onCommandFinished: (UUID) -> Void
    let onAdaptiveBackgroundChange: (UUID, CGColor?) -> Void
    let onToggleZoom: (UUID) -> Void
    /// When present, each leaf (except the dragged pane's own) becomes a drop
    /// target for grab-handle pane drags, reporting into the shared workspace
    /// resolution (see `PaneDropContext`).
    let paneDrop: PaneDropContext?

    init(
        node: SplitNode,
        focusedPaneID: UUID?,
        zoomedPaneID: UUID? = nil,
        isActiveProject: Bool,
        projectID: UUID,
        isSplit: Bool = false,
        onFocusPane: @escaping (UUID) -> Void,
        onSplit: @escaping (UUID, SplitDirection) -> Void,
        onClosePane: @escaping (UUID) -> Void,
        onCommandFinished: @escaping (UUID) -> Void = { _ in },
        onAdaptiveBackgroundChange: @escaping (UUID, CGColor?) -> Void = { _, _ in },
        onToggleZoom: @escaping (UUID) -> Void = { _ in },
        paneDrop: PaneDropContext? = nil
    ) {
        self.node = node
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.isActiveProject = isActiveProject
        self.projectID = projectID
        self.isSplit = isSplit
        self.onFocusPane = onFocusPane
        self.onSplit = onSplit
        self.onClosePane = onClosePane
        self.onCommandFinished = onCommandFinished
        self.onAdaptiveBackgroundChange = onAdaptiveBackgroundChange
        self.onToggleZoom = onToggleZoom
        self.paneDrop = paneDrop
    }

    var body: some View {
        switch node {
        case let .pane(pane):
            SplitLeafView(
                pane: pane,
                isFocused: focusedPaneID == pane.id && isActiveProject,
                isZoomed: zoomedPaneID == pane.id,
                isSplit: isSplit,
                onFocus: { onFocusPane(pane.id) },
                onProcessExit: { onClosePane(pane.id) },
                onCommandFinished: { onCommandFinished(pane.id) },
                onAdaptiveBackgroundChange: { onAdaptiveBackgroundChange(pane.id, $0) },
                onSplitRequest: { dir in onSplit(pane.id, dir) },
                onZoomRequest: { onToggleZoom(pane.id) },
                paneDrop: paneDrop
            )

        case let .split(branch):
            SplitDividerView(branch: branch) {
                SplitTreeView(
                    node: branch.first,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onCommandFinished: onCommandFinished,
                    onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                    onToggleZoom: onToggleZoom,
                    paneDrop: paneDrop
                )
                .id(branch.first.id)
            } second: {
                SplitTreeView(
                    node: branch.second,
                    focusedPaneID: focusedPaneID,
                    zoomedPaneID: zoomedPaneID,
                    isActiveProject: isActiveProject,
                    projectID: projectID,
                    isSplit: true,
                    onFocusPane: onFocusPane,
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onCommandFinished: onCommandFinished,
                    onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                    onToggleZoom: onToggleZoom,
                    paneDrop: paneDrop
                )
                .id(branch.second.id)
            }
        }
    }
}

/// One leaf of the split tree: the terminal pane plus the grab handle that
/// starts a pane drag and the leaf's own pane-drop capture, which reports
/// into the shared workspace resolution (see `PaneDropContext`).
private struct SplitLeafView: View {
    let pane: Pane
    let isFocused: Bool
    let isZoomed: Bool
    let isSplit: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection) -> Void
    let onZoomRequest: () -> Void
    let paneDrop: PaneDropContext?

    var body: some View {
        TerminalPane(
            pane: pane,
            focused: isFocused,
            isZoomed: isZoomed,
            onFocus: onFocus,
            onProcessExit: onProcessExit,
            onCommandFinished: onCommandFinished,
            onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
            onSplitRequest: { dir, _ in onSplitRequest(dir) },
            onZoomRequest: onZoomRequest
        )
        .overlay {
            if !isFocused, isSplit, pane.adaptiveBackgroundColor == nil {
                // Theme-derived dim (not fixed black) so an unfocused pane
                // dims correctly on light themes too, at the user-configured
                // opacity (#156). A pane whose TUI supplies its own adaptive
                // background stays color-accurate even while unfocused.
                MactermTheme.dimOverlay(opacity: Preferences.shared.paneDimOpacity)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // Pane-drag drop capture, one target per leaf: AppKit only fires
            // dragging-entered on a transition INTO a destination, so a
            // whole-workspace target never hears about a drag that started
            // inside it. The dragged pane's own leaf carries no target.
            if let paneDrop, paneDrop.draggedPaneID != pane.id {
                GeometryReader { geo in
                    Color.clear.onDrop(of: paneDrop.acceptedTypes, delegate: LeafDropDelegate(
                        context: paneDrop,
                        paneID: pane.id,
                        viewSize: geo.size
                    ))
                }
            }
        }
        .overlay {
            // Dragging the only pane of a tab has nowhere to go — the
            // handle only exists once the tab is split.
            if isSplit {
                PaneGrabHandle(pane: pane)
            }
        }
    }
}

/// A resizable split container with a draggable divider.
struct SplitDividerView<First: View, Second: View>: View {
    let branch: SplitBranch
    @ViewBuilder
    let first: First
    @ViewBuilder
    let second: Second

    var body: some View {
        GeometryReader { geo in
            let h = branch.direction == .horizontal
            let total = h ? geo.size.width : geo.size.height
            let firstSize = max(0, total * branch.ratio - 0.5)
            let secondSize = max(0, total * (1 - branch.ratio) - 0.5)
            let layout = h ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

            layout {
                first.frame(width: h ? firstSize : nil, height: h ? nil : firstSize)

                Color.clear
                    .frame(width: h ? 1 : nil, height: h ? nil : 1)
                    .overlay(Rectangle().fill(MactermTheme.border))

                second.frame(width: h ? secondSize : nil, height: h ? nil : secondSize)
            }
            // The grab band is layered OVER both panes rather than attached to
            // the hairline, because a target that sits under a pane is no
            // target at all: each pane is a real NSView that consumes mouseDown
            // itself, so the old overlay-on-the-divider gesture was reachable
            // only in the 1pt gap between them — the "you have to be very
            // precise" of #260. Being a sibling in the layout wouldn't help
            // either; the second pane is drawn after the divider and would
            // cover the half of the band that overlaps it.
            .overlay {
                let offset = SplitDividerMetrics.bandOffset(total: total, ratio: branch.ratio)

                layout {
                    Color.clear
                        .frame(width: h ? offset : nil, height: h ? nil : offset)
                        .allowsHitTesting(false)

                    SplitResizeBand(
                        horizontal: h,
                        axisLength: total,
                        ratioAtDragStart: { branch.ratio },
                        onResize: { branch.ratio = $0 }
                    )
                    .frame(
                        width: h ? SplitDividerMetrics.bandThickness : nil,
                        height: h ? nil : SplitDividerMetrics.bandThickness
                    )

                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Pure geometry for the divider's drag band (#260).
enum SplitDividerMetrics {
    /// Thickness of the invisible grab band, centered on the 1pt divider. It
    /// deliberately reaches a few points into both panes — the hairline alone
    /// is far too fine a thing to aim a pointer at. Matches the size ghostty
    /// gives its own split dividers.
    static let bandThickness: CGFloat = 10
    /// How far the divider can be dragged, same bounds as `SplitNode`'s own
    /// clamp and the `pane.resize-split` contract.
    static let minRatio: CGFloat = 0.15
    static let maxRatio: CGFloat = 0.85

    /// Distance from the container's leading (or top) edge to the start of the
    /// grab band: centered on the divider, kept inside the container so the
    /// band never hangs off an edge.
    static func bandOffset(total: CGFloat, ratio: CGFloat) -> CGFloat {
        min(max(total * ratio - bandThickness / 2, 0), max(total - bandThickness, 0))
    }

    /// The ratio a drag lands on, measured from the ratio captured at
    /// mouse-down plus the total distance travelled since.
    static func draggedRatio(start: CGFloat, delta: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return start }
        return min(max(start + delta / total, minRatio), maxRatio)
    }
}

/// The divider's drag target: a transparent AppKit view sized to a comfortable
/// grab band and layered above the panes.
///
/// AppKit rather than a SwiftUI `DragGesture` because the panes it covers are
/// `GhosttyTerminalNSView`s, which handle `mouseDown` themselves and win AppKit
/// hit testing against any SwiftUI gesture underneath them.
private struct SplitResizeBand: NSViewRepresentable {
    let horizontal: Bool
    /// The container's size along the split axis, which is what turns the
    /// drag's distance in points into a ratio.
    let axisLength: CGFloat
    /// Read once at mouse-down, so the whole drag is measured from a single
    /// origin instead of accumulating against a divider that moves with it.
    let ratioAtDragStart: () -> CGFloat
    /// The ratio the drag has reached, already clamped.
    let onResize: (CGFloat) -> Void

    func makeNSView(context _: Context) -> BandView {
        let view = BandView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BandView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: BandView) {
        view.horizontal = horizontal
        view.axisLength = axisLength
        view.ratioAtDragStart = ratioAtDragStart
        view.onResize = onResize
    }

    final class BandView: NSView {
        var horizontal = true
        var axisLength: CGFloat = 0
        var ratioAtDragStart: () -> CGFloat = { 0.5 }
        var onResize: (CGFloat) -> Void = { _ in }

        /// Where the press that started the current drag landed, in WINDOW
        /// coordinates: the band itself travels with the divider mid-drag, so a
        /// view-local origin would move out from under the measurement.
        private var dragOrigin: NSPoint?
        /// The ratio that drag started from — kept here rather than in SwiftUI
        /// state, which wouldn't be guaranteed to have flowed back through
        /// `updateNSView` before the first `mouseDragged` arrives.
        private var startRatio: CGFloat = 0.5

        /// Set while resolving what the band is covering, so its own `hitTest`
        /// steps aside and the view underneath answers instead.
        private var isTransparentToHitTest = false

        private var cursor: NSCursor {
            horizontal ? .resizeLeftRight : .resizeUpDown
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        /// The tracking area owns the resize cursor for the whole hover and
        /// AppKit restores the previous one on exit — no push/pop pair left
        /// stranded when the divider leaves the hierarchy mid-hover (pane
        /// close, zoom toggle, tab switch), which the SwiftUI `onHover` path
        /// this replaced had to unwind by hand.
        override func cursorUpdate(with _: NSEvent) {
            cursor.set()
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
            startRatio = ratioAtDragStart()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            let now = event.locationInWindow
            // Window space is Y-up; the layout (and so the ratio) grows
            // downward, so a vertical split reads the delta inverted.
            let delta = horizontal ? now.x - dragOrigin.x : dragOrigin.y - now.y
            // Hold the resize cursor for the duration: dragging routinely
            // wanders off the band, and `cursorUpdate` only fires for
            // mouse-moved events, which a drag doesn't produce.
            cursor.set()
            onResize(SplitDividerMetrics.draggedRatio(start: startRatio, delta: delta, total: axisLength))
        }

        override func mouseUp(with _: NSEvent) {
            dragOrigin = nil
        }

        // MARK: - Pass-through

        // The band claims the left button — the resize drag — and nothing
        // else. Scrolling or right-clicking a few points from a divider still
        // belongs to the pane the band is sitting on, and AppKit would
        // otherwise drop those events: the responder chain runs up through the
        // band's ancestors, never across to the sibling underneath it.

        override func hitTest(_ point: NSPoint) -> NSView? {
            isTransparentToHitTest ? nil : super.hitTest(point)
        }

        /// The view an event would have reached had the band not been there.
        private func viewBeneath(_ event: NSEvent) -> NSView? {
            isTransparentToHitTest = true
            defer { isTransparentToHitTest = false }
            let target = window?.contentView?.hitTest(event.locationInWindow)
            return target === self ? nil : target
        }

        override func scrollWheel(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.scrollWheel(with: event) }
            target.scrollWheel(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.rightMouseDown(with: event) }
            target.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.rightMouseUp(with: event) }
            target.rightMouseUp(with: event)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.otherMouseDown(with: event) }
            target.otherMouseDown(with: event)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.otherMouseUp(with: event) }
            target.otherMouseUp(with: event)
        }
    }
}
