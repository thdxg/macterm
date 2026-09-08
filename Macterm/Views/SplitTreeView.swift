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
    /// Panes attached to a session another pane is currently driving — zmx
    /// non-leaders (#345). They render live output laid out for the leader's
    /// geometry, so they are dimmed to say "not the live size".
    let nonLeaderPaneIDs: Set<UUID>
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
        nonLeaderPaneIDs: Set<UUID> = [],
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
        self.nonLeaderPaneIDs = nonLeaderPaneIDs
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
                isNonLeaderMirror: nonLeaderPaneIDs.contains(pane.id),
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
                    nonLeaderPaneIDs: nonLeaderPaneIDs,
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
                    nonLeaderPaneIDs: nonLeaderPaneIDs,
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
    let isNonLeaderMirror: Bool
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
            isNonLeaderMirror: isNonLeaderMirror,
            onFocus: onFocus,
            onProcessExit: onProcessExit,
            onCommandFinished: onCommandFinished,
            onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
            onSplitRequest: { dir, _ in onSplitRequest(dir) },
            onZoomRequest: onZoomRequest
        )
        .overlay {
            if isNonLeaderMirror {
                // A non-leader mirror (#345) is BLURRED, not dimmed. It is not
                // about focus — it says the pane is not the one driving the
                // session's pty size, so it is rendering live output laid out
                // for another pane's geometry: a TUI in it is genuinely
                // garbled. The blur hides that layout and marks the view the
                // user is not working in; a dim would label it and leave the
                // garble legible. Neither split-dim gate applies: `isSplit` is
                // false for a single-pane tab and for a zoomed pane, exactly
                // the common mirrored case, and an adaptive background must
                // not exempt it.
                NonLeaderBlur()
                    .overlay(MactermTheme.dimOverlay)
                    .allowsHitTesting(false)
            } else if !isFocused, isSplit, pane.adaptiveBackgroundColor == nil {
                // Driven by the user's ghostty `unfocused-split-opacity` /
                // `unfocused-split-fill`, same as Ghostty.app's split dim. A
                // pane whose TUI supplies its own adaptive background stays
                // color-accurate even while unfocused.
                MactermTheme.dimOverlay
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

                    ResizeDragBand(
                        axis: h ? .horizontal : .vertical,
                        valueAtDragStart: { branch.ratio },
                        resizedValue: { start, delta in
                            SplitDividerMetrics.draggedRatio(start: start, delta: delta, total: total)
                        },
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

enum ResizeDragAxis {
    case horizontal
    case vertical

    fileprivate var cursor: NSCursor {
        switch self {
        case .horizontal: .resizeLeftRight
        case .vertical: .resizeUpDown
        }
    }

    /// Convert AppKit's Y-up window coordinates into the layout's down-positive
    /// vertical axis. Horizontal coordinates already grow in the same direction.
    func delta(from origin: NSPoint, to current: NSPoint) -> CGFloat {
        switch self {
        case .horizontal: current.x - origin.x
        case .vertical: origin.y - current.y
        }
    }
}

/// Shared transparent AppKit drag target for split and sidebar resize bands.
///
/// AppKit rather than a SwiftUI `DragGesture` so the band keeps receiving a
/// drag after the pointer leaves its narrow bounds and can sit over terminal
/// NSViews that win AppKit hit testing. The band claims only the left-button
/// drag; scrolling and other mouse buttons pass through to the view beneath it.
struct ResizeDragBand: NSViewRepresentable {
    let axis: ResizeDragAxis
    /// Read once at mouse-down, so the drag is measured from a stable value.
    let valueAtDragStart: () -> CGFloat
    /// Convert the captured start value and current drag delta into the new
    /// caller-specific value (split ratio or sidebar width).
    let resizedValue: (CGFloat, CGFloat) -> CGFloat
    let onResize: (CGFloat) -> Void
    let onResizeStateChanged: (Bool) -> Void

    init(
        axis: ResizeDragAxis,
        valueAtDragStart: @escaping () -> CGFloat,
        resizedValue: @escaping (CGFloat, CGFloat) -> CGFloat,
        onResize: @escaping (CGFloat) -> Void,
        onResizeStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.axis = axis
        self.valueAtDragStart = valueAtDragStart
        self.resizedValue = resizedValue
        self.onResize = onResize
        self.onResizeStateChanged = onResizeStateChanged
    }

    func makeNSView(context _: Context) -> BandView {
        let view = BandView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BandView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: BandView) {
        view.axis = axis
        view.valueAtDragStart = valueAtDragStart
        view.resizedValue = resizedValue
        view.onResize = onResize
        view.onResizeStateChanged = onResizeStateChanged
    }

    final class BandView: NSView {
        var axis: ResizeDragAxis = .horizontal
        var valueAtDragStart: () -> CGFloat = { 0 }
        var resizedValue: (CGFloat, CGFloat) -> CGFloat = { start, delta in start + delta }
        var onResize: (CGFloat) -> Void = { _ in }
        var onResizeStateChanged: (Bool) -> Void = { _ in }

        /// Where the press that started the current drag landed, in WINDOW
        /// coordinates: the band itself travels with the divider mid-drag, so a
        /// view-local origin would move out from under the measurement.
        private var dragOrigin: NSPoint?
        /// The value that drag started from — kept here rather than in SwiftUI
        /// state, which wouldn't be guaranteed to have flowed back through
        /// `updateNSView` before the first `mouseDragged` arrives.
        private var startValue: CGFloat = 0
        /// The press that opened the current drag, kept so a click that never
        /// became a drag can be handed to the view underneath on release.
        private var pressEvent: NSEvent?
        private var didDrag = false

        /// Set while resolving what the band is covering, so its own `hitTest`
        /// steps aside and the view underneath answers instead.
        private var isTransparentToHitTest = false

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
            axis.cursor.set()
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
            startValue = valueAtDragStart()
            pressEvent = event
            didDrag = false
            onResizeStateChanged(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            didDrag = true
            let delta = axis.delta(from: dragOrigin, to: event.locationInWindow)
            // Hold the resize cursor for the duration: dragging routinely
            // wanders off the band, and `cursorUpdate` only fires for
            // mouse-moved events, which a drag doesn't produce.
            axis.cursor.set()
            onResize(resizedValue(startValue, delta))
        }

        override func mouseUp(with event: NSEvent) {
            let press = pressEvent
            let moved = didDrag
            finishResize()
            // A press that never moved isn't a resize. The band sits ON the
            // view it covers — for the sidebar overlay that is the row list,
            // whose trailing points would otherwise be dead to selection — so
            // hand the click down, the same way scroll and right-click already
            // go through `viewBeneath`. The release is queued FIRST: a target
            // that tracks inside `mouseDown` then reads it immediately instead
            // of blocking on the next event.
            guard !moved, let press, let target = viewBeneath(press) else { return }
            NSApp.postEvent(event, atStart: true)
            target.mouseDown(with: press)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // A style switch or shortcut can remove the overlay mid-drag. End
            // the shared lifecycle here so its owner never stays permanently
            // stuck in a resizing state after this view disappears.
            if newWindow == nil { finishResize() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func finishResize() {
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            pressEvent = nil
            didDrag = false
            onResizeStateChanged(false)
        }

        // MARK: - Pass-through

        // The band claims the left button — the resize drag — and nothing
        // else. Scrolling or right-clicking a few points from a resize edge
        // still belongs to the view underneath, and AppKit would otherwise drop
        // those events: the responder chain runs up through the band's
        // ancestors, never across to the sibling underneath it.

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

/// The blur over a non-leader mirror (#345).
///
/// The terminal underneath keeps rendering; this only blurs what is composited
/// beneath it. An AppKit layer with Core Image `backgroundFilters`, not
/// SwiftUI's `.blur` (which cannot reach a hosted `CAMetalLayer`) and not an
/// `NSVisualEffectView` (whose materials tint and mostly hide the content —
/// the first cut used `.hudWindow` and read as an opaque slab). It sits ON a
/// pane, so it must take no mouse input of its own — `allowsHitTesting(false)`
/// does not stop a hosted NSView from winning AppKit hit testing, so `hitTest`
/// is overridden to yield.
private struct NonLeaderBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> BackdropBlurView {
        BackdropBlurView()
    }

    func updateNSView(_: BackdropBlurView, context _: Context) {}
}

private final class BackdropBlurView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Required for Core Image filters on a layer-backed view; without it
        // `backgroundFilters` is silently ignored.
        layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(6, forKey: kCIInputRadiusKey)
            layer?.backgroundFilters = [blur]
        }
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
