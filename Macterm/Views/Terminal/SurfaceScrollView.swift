import AppKit
import GhosttyKit

/// Native overlay scrollbar for a terminal surface, mirroring Ghostty's macOS
/// approach (Ghostty 1.3.0+, `SurfaceScrollView`).
///
/// The trick: nest the Metal terminal surface inside a standard `NSScrollView`
/// whose `documentView` is a **blank spacer** sized to the full scrollback
/// height. AppKit then renders and hit-tests a real overlay scroller (auto-hide
/// / fade for free) and the surface only ever draws the visible viewport.
///
/// ```
/// SurfaceScrollView : NSScrollView
///   └─ documentView : NSView          (blank, height = total rows * cellHeight)
///        └─ GhosttyTerminalNSView      (pinned to the visible rect)
/// ```
///
/// Wheel/trackpad events hit the frontmost surface view first. Ordinary
/// scrollback gestures are handled here with an iTerm2-style line accumulator
/// that converts AppKit's wheel/trackpad deltas (including inertia) into whole
/// terminal-row movement; mouse-reporting / alt-screen cases continue to go to
/// libghostty. Scrollback geometry flows **into** this view via the
/// `GHOSTTY_ACTION_SCROLLBAR` action (`onScrollbarUpdate`), and user-visible
/// scroll positions flow **out** via the `scroll_to_row:<n>` keybind action.
final class SurfaceScrollView: NSScrollView {
    /// The Metal terminal surface. Owned by `Pane`; we just re-parent it into
    /// our document view.
    let surfaceView: GhosttyTerminalNSView

    /// The blank spacer whose height represents the full scrollback.
    private let spacer = NSView()

    /// Latest scrollback geometry pushed by libghostty, in rows.
    private var total: UInt64 = 0
    private var offset: UInt64 = 0
    private var len: UInt64 = 0

    /// True while the user is dragging the scroller (live scroll). During a
    /// drag we resize the document but must not programmatically scroll the clip
    /// view — that would fight the user's gesture.
    private var isLiveScrolling = false

    /// Last row index sent to the core via `scroll_to_row`, to dedupe spam.
    private var lastSentRow: Int = -1

    /// iTerm-style vertical scroll-wheel accumulator. It turns AppKit's messy
    /// wheel/trackpad deltas into whole terminal-row movement, including
    /// momentum events, instead of trying to pixel-scroll terminal contents.
    private let verticalScrollAccumulator = ITermScrollAccumulator()

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(surfaceView: GhosttyTerminalNSView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)

        // Overlay style always: matches Ghostty, gives auto-hide/fade for free,
        // and overlays the grid without reserving a gutter (so the surface is
        // never resized by the scrollbar appearing).
        scrollerStyle = .overlay
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        usesPredominantAxisScrolling = true
        verticalScrollElasticity = .none
        // The window composites its own translucency (see WindowAppearance);
        // drawing a background here would double-tint.
        drawsBackground = false
        contentView.drawsBackground = false
        // Let the surface paint the full visible rect without the clip view
        // clipping its layer at the edges.
        contentView.clipsToBounds = false

        spacer.translatesAutoresizingMaskIntoConstraints = true
        spacer.addSubview(surfaceView)
        documentView = spacer

        wireObservers()
        surfaceView.onScrollbarUpdate = { [weak self] total, offset, len in
            self?.applyScrollbar(total: total, offset: offset, len: len)
        }
        surfaceView.onScrollWheel = { [weak self] event in
            self?.handleSurfaceScrollWheel(event) ?? false
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated { surfaceView.onScrollWheel = nil }
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Observers

    private func wireObservers() {
        let nc = NotificationCenter.default

        let willStart = nc.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveScrolling = true } }

        let didLive = nc.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: self, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleLiveScroll() } }

        let didEnd = nc.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveScrolling = false } }

        // Keep the surface pinned to the visible rect as the clip view moves.
        contentView.postsBoundsChangedNotifications = true
        let bounds = nc.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layoutSurface() } }

        // Re-assert overlay style if the user toggles the system "always show
        // scrollbars" preference.
        let style = nc.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scrollerStyle = .overlay } }

        observers = [willStart, didLive, didEnd, bounds, style]
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        synchronize()
    }

    /// Pin the surface to fill the currently visible rect of the document.
    private func layoutSurface() {
        let visible = contentView.documentVisibleRect
        // The surface always fills exactly what's on screen; libghostty renders
        // the viewport, not the whole scrollback.
        surfaceView.frame = visible
    }

    /// Resize the spacer to the full scrollback height and, unless the user is
    /// mid-drag, scroll the clip view to mirror libghostty's viewport.
    private func synchronize() {
        let cellHeight = surfaceView.cellHeightPoints
        let viewportHeight = contentView.bounds.height
        guard cellHeight > 0, viewportHeight > 0 else {
            // Surface not ready: spacer matches the viewport (no scrollback).
            spacer.frame = NSRect(origin: .zero, size: contentView.bounds.size)
            layoutSurface()
            return
        }

        verticalLineScroll = cellHeight
        let docHeight = Self.documentHeight(total: total, cellHeight: cellHeight, viewportHeight: viewportHeight)
        if spacer.frame.height != docHeight || spacer.frame.width != contentView.bounds.width {
            spacer.frame = NSRect(x: 0, y: 0, width: contentView.bounds.width, height: docHeight)
        }

        if !isLiveScrolling {
            let y = Self.documentOffsetY(total: total, offset: offset, len: len, cellHeight: cellHeight)
            contentView.scroll(to: NSPoint(x: 0, y: y))
            reflectScrolledClipView(contentView)
        }
        layoutSurface()
    }

    // MARK: - Core → UI

    private func applyScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        self.total = total
        self.offset = offset
        self.len = len
        synchronize()
    }

    // MARK: - UI → Core

    private func handleSurfaceScrollWheel(_ event: NSEvent) -> Bool {
        let cellHeight = surfaceView.cellHeightPoints
        guard canHandleScrollbackWheel(event, cellHeight: cellHeight) else { return false }
        let rowDelta = verticalScrollAccumulator.delta(for: event, sensitivity: Preferences.shared.terminalScrollSpeed)
        guard rowDelta != 0 else { return true }
        let currentRow = Int(min(offset, UInt64(Int.max)))
        sendScrollToRow(currentRow - rowDelta)
        return true
    }

    private func canHandleScrollbackWheel(_ event: NSEvent, cellHeight: CGFloat) -> Bool {
        guard surfaceView.surface != nil, cellHeight > 0, total > len else { return false }
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellHeightPoints
        guard cellHeight > 0, surfaceView.surface != nil else { return }
        let visible = contentView.documentVisibleRect
        let docHeight = spacer.frame.height
        let row = Self.rowFromOffset(
            visibleOriginY: visible.origin.y,
            visibleHeight: visible.height,
            documentHeight: docHeight,
            cellHeight: cellHeight
        )
        guard row != lastSentRow else {
            layoutSurface()
            return
        }
        sendScrollToRow(row)
        layoutSurface()
    }

    private func sendScrollToRow(_ requestedRow: Int) {
        guard let surface = surfaceView.surface else { return }
        let maxScrollable = total > len ? total - len : 0
        let maxRow = Int(min(maxScrollable, UInt64(Int.max)))
        let row = min(max(0, requestedRow), maxRow)
        guard row != lastSentRow else { return }
        lastSentRow = row

        // Keep the native scroller in step immediately, like iTerm2's
        // `scrollRectToVisible`, while the row-based terminal core catches up.
        offset = UInt64(row)
        synchronize()

        let action = "scroll_to_row:\(row)"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Legacy scroller discoverability

    private var scrollerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = scrollerTracking { removeTrackingArea(existing) }
        guard let scroller = verticalScroller else { return }
        let area = NSTrackingArea(
            rect: scroller.frame,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        scrollerTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // With a legacy "always show scrollbars" preference we force overlay
        // style, which would otherwise hide the click-drag affordance. Flash the
        // scroller when the pointer is over its track so it stays discoverable.
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        flashScrollers()
    }
}

// MARK: - iTerm2-style scroll accumulation

/// Swift port of iTerm2's `iTermScrollAccumulator`: modern accumulator enabled,
/// `fastTrackpad = YES`, configurable sensitivity, and scroll-wheel acceleration
/// 1.0.
private final class ITermScrollAccumulator {
    private var accumulatedDelta: CGFloat = 0

    func delta(for event: NSEvent, sensitivity: Double) -> Int {
        let sensitivity = CGFloat(max(0.25, min(3.0, sensitivity)))
        let accumulated = accumulatedDelta(for: event, sensitivity: sensitivity)
        let sign: CGFloat = accumulated > 0 ? 1 : -1
        return Int(pow(abs(accumulated), 1) * sign)
    }

    private func accumulatedDelta(for event: NSEvent, sensitivity: CGFloat) -> CGFloat {
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            return accumulatedDeltaForMouseWheelEvent(event, sensitivity: sensitivity)
        }
        return accumulatedDeltaForTrackpadEvent(event, sensitivity: sensitivity)
    }

    private func accumulatedDeltaForMouseWheelEvent(_ event: NSEvent, sensitivity: CGFloat) -> CGFloat {
        let delta = adjustedDelta(for: event)
        if sensitivity == 1 {
            let roundDelta = delta.rounded()
            if roundDelta == 0, delta != 0 {
                return delta > 0 ? 1 : -1
            }
            return roundDelta
        }
        accumulatedDelta += delta * sensitivity
        return takeWholePortion(delta: delta)
    }

    private func accumulatedDeltaForTrackpadEvent(_ event: NSEvent, sensitivity: CGFloat) -> CGFloat {
        if event.phase == .began {
            accumulatedDelta = 0
        }
        let delta = adjustedDelta(for: event) * sensitivity
        accumulatedDelta += delta
        return takeWholePortion(delta: delta)
    }

    private func adjustedDelta(for event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            // iTerm2's `fastTrackpad` path, based on Terminal.app: use the
            // device line delta and round away from zero so small trackpad
            // gestures don't feel sluggish.
            return Self.roundAwayFromZero(event.deltaY)
        }
        return event.scrollingDeltaY
    }

    private func takeWholePortion(delta: CGFloat) -> CGFloat {
        if abs(accumulatedDelta) >= 1 {
            let roundDelta = Self.roundTowardZero(accumulatedDelta)
            accumulatedDelta -= roundDelta
            return roundDelta
        }
        if delta * accumulatedDelta < 0 {
            accumulatedDelta = 0
            return delta.rounded()
        }
        return 0
    }

    private static func roundTowardZero(_ value: CGFloat) -> CGFloat {
        value > 0 ? floor(value) : ceil(value)
    }

    private static func roundAwayFromZero(_ value: CGFloat) -> CGFloat {
        value > 0 ? ceil(value) : floor(value)
    }
}

// MARK: - Pure geometry

extension SurfaceScrollView {
    /// Height of the blank document view (points). At least the viewport height
    /// so there's nothing to scroll when scrollback is empty.
    nonisolated static func documentHeight(total: UInt64, cellHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(CGFloat(total) * cellHeight, viewportHeight)
    }

    /// AppKit clip-view origin (points, Y-up from the document bottom) that
    /// places the visible region over libghostty's current viewport.
    ///
    /// libghostty's `offset` is the first visible row counted from the top of
    /// history (Y-down); AppKit scrolls from the bottom (Y-up), so we invert:
    /// rows below the viewport = `total - offset - len`.
    nonisolated static func documentOffsetY(total: UInt64, offset: UInt64, len: UInt64, cellHeight: CGFloat) -> CGFloat {
        let rowsBelow = Int64(total) - Int64(offset) - Int64(len)
        return CGFloat(max(0, rowsBelow)) * cellHeight
    }

    /// Inverse of `documentOffsetY`: the top visible row (from the top of
    /// history) for a given clip-view position. Used when the user drags the
    /// scroller, to tell the core which row to scroll to.
    nonisolated static func rowFromOffset(
        visibleOriginY: CGFloat,
        visibleHeight: CGFloat,
        documentHeight: CGFloat,
        cellHeight: CGFloat
    ) -> Int {
        guard cellHeight > 0 else { return 0 }
        let topFromTop = documentHeight - visibleOriginY - visibleHeight
        return max(0, Int(topFromTop / cellHeight))
    }
}
