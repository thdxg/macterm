import CoreGraphics
import Foundation

/// Where a terminal joined through a sidebar row lands INSIDE that tab.
///
/// A split tab's row draws one segment per pane, so the gaps between those
/// segments are positions the user can already see — dropping on one means
/// "put it here", in that order. This turns a pointer position into that
/// choice, and the choice into a drop target the split tree understands.
enum TabMergePlacement {
    /// The insertion boundary nearest `x` across a row of `paneCount`
    /// equal-width segments: 0 is before the first pane, `paneCount` is after
    /// the last, and everything between sits at a segment seam.
    ///
    /// Rounding to the NEAREST boundary rather than flooring into a segment is
    /// what makes both ends reachable: flooring never yields `paneCount`, so
    /// "after the last pane" — the commonest intent — would be unhittable.
    static func insertionIndex(x: CGFloat, width: CGFloat, paneCount: Int) -> Int {
        guard paneCount > 0, width > 0 else { return 0 }
        let segment = width / CGFloat(paneCount)
        let boundary = Int((x / segment).rounded())
        return min(max(boundary, 0), paneCount)
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
