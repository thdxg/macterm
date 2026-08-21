import CoreGraphics
import Foundation

/// Where a terminal joined through a sidebar row lands INSIDE that tab.
///
/// A split tab's row draws one segment per pane, so the gaps between those
/// segments are positions the user can already see — dropping on one means
/// "put it here", in that order. This turns a pointer position into that
/// choice, and the choice into a drop target the split tree understands.
enum TabMergePlacement {
    /// The x positions a join can land on, derived from where the row ACTUALLY
    /// drew its segments.
    ///
    /// Computing them as even fractions of the row width was wrong by a few
    /// points: the segments sit inside the row's label area, spaced apart with
    /// a hairline divider between them, so an even split lands beside the
    /// divider rather than on it — and the indicator has to line up with the
    /// `|` the user is aiming at. Interior seams are therefore the MIDPOINT of
    /// each gap, which is exactly where the divider is drawn.
    ///
    /// A row with fewer than two segments has no seam to show (its title is
    /// one piece, or it collapsed to a pane count) and returns none; the caller
    /// falls back to appending at the trailing edge.
    static func seams(segmentFrames: [CGRect]) -> [CGFloat] {
        guard segmentFrames.count > 1 else { return [] }
        let ordered = segmentFrames.sorted { $0.minX < $1.minX }
        var result: [CGFloat] = [ordered[0].minX]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            result.append((left.maxX + right.minX) / 2)
        }
        result.append(ordered[ordered.count - 1].maxX)
        return result
    }

    /// The seam nearest `x`. Nearest rather than "the segment `x` falls in":
    /// falling-in can never choose the last seam, and "after everything" is the
    /// commonest intent there is.
    static func insertionIndex(x: CGFloat, seams: [CGFloat]) -> Int {
        guard !seams.isEmpty else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, seam) in seams.enumerated() {
            let distance = abs(seam - x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// The drop target for an insertion boundary, given the tab's panes in
    /// tree order.
    ///
    /// Every boundary resolves to a LOCAL split beside a specific pane rather
    /// than a whole-edge drop: the point of choosing a position is to land
    /// between two named terminals, and a root-edge drop would instead put the
    /// arrival beside the entire tree — the same result no matter which seam
    /// was aimed at. Interior boundaries are expressed as "right of the pane
    /// before" (identical to "left of the pane after", but one rule).
    static func target(insertionIndex index: Int, panes: [UUID]) -> TabDropResolution.Target? {
        guard let first = panes.first, let last = panes.last else { return nil }
        if index <= 0 { return .pane(first, .left) }
        if index >= panes.count { return .pane(last, .right) }
        return .pane(panes[index - 1], .right)
    }
}
