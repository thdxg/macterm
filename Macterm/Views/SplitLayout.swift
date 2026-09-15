import CoreGraphics
import Foundation

/// A split tree resolved to absolute rectangles: one per pane, one hairline
/// plus one grab band per branch. Pure geometry, the flat counterpart of the
/// nested frames `SplitDividerView` computes — same arithmetic, so the two
/// renderers tile a tree identically and toggling between them moves nothing.
///
/// `AnimatedSplitView` renders these in one ZStack keyed by pane ID. Because
/// every leaf's frame is then a plain animatable value on a stable identity,
/// any tree change (split, close, zoom, a pane dragged to another branch,
/// auto-tiling's rebalance) is a set of frames moving, which is exactly what
/// a compositor animates. The recursive view can't: SwiftUI cannot animate
/// across the structural identity change a re-nesting causes.
struct SplitLayout: Equatable {
    /// Where a leaf sits in the split that made it: the branch's axis, which
    /// of its two sides the leaf is, and the branch's whole rect — the strip
    /// the leaf shares with its sibling, which is what a slide is confined
    /// to. nil for a tab's only pane.
    struct Placement: Equatable {
        let axis: SplitDirection
        let position: SplitPosition
        let branchRect: CGRect
    }

    struct Leaf: Identifiable, Equatable {
        let pane: Pane
        let rect: CGRect
        let placement: Placement?

        var id: UUID { pane.id }

        static func == (lhs: Leaf, rhs: Leaf) -> Bool {
            lhs.pane === rhs.pane && lhs.rect == rhs.rect && lhs.placement == rhs.placement
        }
    }

    struct Divider: Identifiable, Equatable {
        let branch: SplitBranch
        /// The 1pt hairline between the two children.
        let rect: CGRect
        /// The grab band centred on the hairline (`SplitDividerMetrics`).
        let bandRect: CGRect
        /// Extent of the branch along its split axis — what a drag delta is
        /// measured against (`SplitDividerMetrics.draggedRatio`).
        let total: CGFloat
        /// Copied from the branch at resolve time (`SplitBranch` is
        /// main-actor; `Equatable` is not).
        let axis: SplitDirection
        /// The branch's whole rect.
        let branchRect: CGRect
        /// Node IDs of the two children (a pane's node ID is its pane ID), so
        /// a new divider can tell which side is the pane arriving beside it.
        let firstID: UUID
        let secondID: UUID

        var id: UUID { branch.id }

        static func == (lhs: Divider, rhs: Divider) -> Bool {
            lhs.branch === rhs.branch && lhs.rect == rhs.rect && lhs.bandRect == rhs.bandRect
        }
    }

    /// Thickness of the hairline between two children.
    static let dividerThickness: CGFloat = 1

    private(set) var leaves: [Leaf] = []
    private(set) var dividers: [Divider] = []

    /// Tree order (first before second, depth first), the order the recursive
    /// view draws them in.
    @MainActor
    static func resolve(_ node: SplitNode, in rect: CGRect) -> SplitLayout {
        var layout = SplitLayout()
        layout.append(node, in: rect, placement: nil)
        return layout
    }

    @MainActor
    private mutating func append(_ node: SplitNode, in rect: CGRect, placement: Placement?) {
        switch node {
        case let .pane(pane):
            leaves.append(Leaf(pane: pane, rect: rect, placement: placement))
        case let .split(branch):
            let horizontal = branch.direction == .horizontal
            let total = horizontal ? rect.width : rect.height
            // Mirrors SplitDividerView: each child gives up half the hairline.
            let firstSize = max(0, total * branch.ratio - Self.dividerThickness / 2)
            let secondSize = max(0, total * (1 - branch.ratio) - Self.dividerThickness / 2)
            let bandOffset = SplitDividerMetrics.bandOffset(total: total, ratio: branch.ratio)
            let band = SplitDividerMetrics.bandThickness

            let firstRect: CGRect
            let dividerRect: CGRect
            let bandRect: CGRect
            let secondRect: CGRect
            if horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstSize, height: rect.height)
                dividerRect = CGRect(
                    x: rect.minX + firstSize, y: rect.minY, width: Self.dividerThickness, height: rect.height
                )
                bandRect = CGRect(x: rect.minX + bandOffset, y: rect.minY, width: band, height: rect.height)
                secondRect = CGRect(
                    x: dividerRect.maxX, y: rect.minY, width: secondSize, height: rect.height
                )
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSize)
                dividerRect = CGRect(
                    x: rect.minX, y: rect.minY + firstSize, width: rect.width, height: Self.dividerThickness
                )
                bandRect = CGRect(x: rect.minX, y: rect.minY + bandOffset, width: rect.width, height: band)
                secondRect = CGRect(
                    x: rect.minX, y: dividerRect.maxY, width: rect.width, height: secondSize
                )
            }

            append(
                branch.first, in: firstRect,
                placement: Placement(axis: branch.direction, position: .first, branchRect: rect)
            )
            dividers.append(Divider(
                branch: branch, rect: dividerRect, bandRect: bandRect, total: total, axis: branch.direction,
                branchRect: rect, firstID: branch.first.id, secondID: branch.second.id
            ))
            append(
                branch.second, in: secondRect,
                placement: Placement(axis: branch.direction, position: .second, branchRect: rect)
            )
        }
    }

    /// `rect` collapsed to nothing against its own outer edge of the split —
    /// the edge of `placement.branchRect` on the leaf's side, away from its
    /// sibling. A new pane grows out from there while the sibling gives up
    /// the space, so the two edges meet at the seam throughout (both move
    /// linearly under one animation) and neither ever draws over the other;
    /// a closing pane's ghost shrinks back into it as the sibling reclaims
    /// the strip. With transparent pane backgrounds any overlap would show
    /// text through text, which is why the motion stays inside the strip.
    /// A lone pane (no placement) has no seam and is returned as is.
    static func collapsed(_ rect: CGRect, placement: Placement?) -> CGRect {
        guard let placement else { return rect }
        let strip = placement.branchRect
        return switch (placement.axis, placement.position) {
        case (.horizontal, .first): CGRect(x: strip.minX, y: rect.minY, width: 0, height: rect.height)
        case (.horizontal, .second): CGRect(x: strip.maxX, y: rect.minY, width: 0, height: rect.height)
        case (.vertical, .first): CGRect(x: rect.minX, y: strip.minY, width: rect.width, height: 0)
        case (.vertical, .second): CGRect(x: rect.minX, y: strip.maxY, width: rect.width, height: 0)
        }
    }

    /// How far a closing pane's content travels while it slides out: its own
    /// length along the axis, toward its own outer edge of the split — a
    /// left or top pane leaves to the left or top, a right or bottom pane to
    /// the right or bottom, mirroring the edge it grew in from. Applied on
    /// top of `collapsed`'s shrinking window: for a `.second` pane the
    /// window's leading edge already moves that way, so the content rides it
    /// and needs no shift; a `.first` pane's window shrinks from the far
    /// side, so the content is shifted toward the near edge itself.
    static func slideOutShift(for rect: CGRect, placement: Placement?) -> CGSize {
        guard let placement, placement.position == .first else { return .zero }
        return switch placement.axis {
        case .horizontal: CGSize(width: -rect.width, height: 0)
        case .vertical: CGSize(width: 0, height: -rect.height)
        }
    }

    /// The hairline at a closing pane's seam: the edge of its ghost's window
    /// that faces the sibling, one `dividerThickness` wide, on the sibling's
    /// side of the window exactly where the branch's divider sat against the
    /// tile. As the window collapses the hairline rides the seam, so the
    /// divider is seen to travel with the retile instead of vanishing.
    static func seamHairline(of window: CGRect, placement: Placement) -> CGRect {
        let t = dividerThickness
        return switch (placement.axis, placement.position) {
        case (.horizontal, .second): CGRect(x: window.minX - t, y: window.minY, width: t, height: window.height)
        case (.horizontal, .first): CGRect(x: window.maxX, y: window.minY, width: t, height: window.height)
        case (.vertical, .second): CGRect(x: window.minX, y: window.minY - t, width: window.width, height: t)
        case (.vertical, .first): CGRect(x: window.minX, y: window.maxY, width: window.width, height: t)
        }
    }

    /// What must change for a layout change to be animated: the tree's
    /// structure by pane identity, plus the zoomed pane. Ratios are left out
    /// on purpose — a divider drag or `pane resize-split` changes ratios only
    /// and must land immediately, while a split or rebalance that changes
    /// ratios in the same transaction as the structure animates with it.
    @MainActor
    static func animationKey(of node: SplitNode, zoomedPaneID: UUID?) -> String {
        "\(structure(of: node))|\(zoomedPaneID?.uuidString ?? "-")"
    }

    @MainActor
    private static func structure(of node: SplitNode) -> String {
        switch node {
        case let .pane(pane):
            pane.id.uuidString
        case let .split(branch):
            "\(branch.direction == .horizontal ? "H" : "V")(\(structure(of: branch.first)),\(structure(of: branch.second)))"
        }
    }
}
