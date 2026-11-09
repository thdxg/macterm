import AppKit

/// A trackpad pinch over a pane zooms or unzooms it (`magnify(with:)` of
/// `GhosttyTerminalNSView`). Upstream Ghostty answers no pinch, and
/// libghostty reads no magnify event, so nothing else uses the gesture.
///
/// One trigger for each gesture: the pinch fires once, when its total
/// magnification first passes `threshold`, and not again until the gesture
/// ends. Without this, one long pinch would zoom and unzoom in turn.
struct PinchZoomGesture {
    enum Direction: Equatable {
        /// Fingers move apart: zoom the pane.
        case outward
        /// Fingers move together: unzoom the pane.
        case inward
    }

    /// Total magnification (the sum of `NSEvent.magnification`) that fires.
    static let threshold: CGFloat = 0.15

    private var total: CGFloat = 0
    private var fired = false

    /// Adds one magnify event. Returns the pinch direction for the one event
    /// that passes the threshold, and nil for every other event.
    mutating func track(phase: NSEvent.Phase, magnification: CGFloat) -> Direction? {
        if phase.contains(.began) {
            total = 0
            fired = false
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            total = 0
            fired = false
            return nil
        }
        guard !fired else { return nil }
        total += magnification
        guard abs(total) >= Self.threshold else { return nil }
        fired = true
        return total > 0 ? .outward : .inward
    }

    /// Whether a pinch toggles the zoom. A pinch out zooms a pane of a split,
    /// and a pinch in unzooms a zoomed pane. A pane that is alone in its tab
    /// (also a desktop widget) has nothing to zoom.
    static func togglesZoom(_ direction: Direction, isZoomed: Bool, isSplit: Bool) -> Bool {
        switch direction {
        case .outward: !isZoomed && isSplit
        case .inward: isZoomed
        }
    }
}
