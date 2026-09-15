import CoreGraphics
@testable import Macterm
import Testing

/// The flat geometry `AnimatedSplitView` renders (Settings → Experimental →
/// Animate splits). UI behaviour isn't unit-tested per the project's
/// conventions, but the rectangles are plain arithmetic worth pinning: they
/// must match the nested frames `SplitDividerView` lays out, so toggling the
/// experiment moves no pane, and the animation key must ignore ratios so a
/// divider drag never animates.
@MainActor
struct SplitLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let hairline = SplitLayout.dividerThickness

    // MARK: - Leaves

    @Test
    func single_pane_fills_the_container() {
        let (tree, ids) = build(pane("a"))
        let layout = SplitLayout.resolve(tree, in: bounds)
        #expect(layout.leaves.map(\.id) == [ids["a"]])
        #expect(layout.leaves[0].rect == bounds)
        #expect(layout.dividers.isEmpty)
    }

    @Test
    func horizontal_split_matches_the_nested_view_arithmetic() throws {
        // SplitDividerView: first = total*ratio - 0.5, hairline 1pt, second =
        // total*(1-ratio) - 0.5, laid out in sequence.
        let (tree, ids) = build(H(pane("l"), pane("r"), ratio: 0.3))
        let layout = SplitLayout.resolve(tree, in: bounds)
        let l = try #require(layout.leaves.first { $0.id == ids["l"] }?.rect)
        let r = try #require(layout.leaves.first { $0.id == ids["r"] }?.rect)
        let divider = layout.dividers[0]

        #expect(l == CGRect(x: 0, y: 0, width: 300 - hairline / 2, height: 600))
        #expect(divider.rect == CGRect(x: l.maxX, y: 0, width: hairline, height: 600))
        #expect(r == CGRect(x: divider.rect.maxX, y: 0, width: 700 - hairline / 2, height: 600))
        // The three tile the container exactly.
        #expect(l.width + divider.rect.width + r.width == bounds.width)
        #expect(divider.total == bounds.width)
        #expect(divider.axis == .horizontal)
    }

    @Test
    func vertical_split_lays_out_along_y() throws {
        let (tree, ids) = build(V(pane("t"), pane("b"), ratio: 0.5))
        let layout = SplitLayout.resolve(tree, in: bounds)
        let t = try #require(layout.leaves.first { $0.id == ids["t"] }?.rect)
        let b = try #require(layout.leaves.first { $0.id == ids["b"] }?.rect)

        #expect(t == CGRect(x: 0, y: 0, width: 1000, height: 300 - hairline / 2))
        #expect(b.minY == t.maxY + hairline)
        #expect(b.maxY == bounds.maxY)
        #expect(layout.dividers[0].axis == .vertical)
        #expect(layout.dividers[0].total == bounds.height)
    }

    @Test
    func nested_tree_resolves_recursively_in_tree_order() throws {
        let (tree, ids) = build(H(pane("l"), V(pane("rt"), pane("rb"))))
        let layout = SplitLayout.resolve(tree, in: bounds)

        // Depth first, first before second — the order the recursive view draws.
        #expect(layout.leaves.map(\.id) == [ids["l"], ids["rt"], ids["rb"]])
        #expect(layout.dividers.count == 2)

        let rt = try #require(layout.leaves.first { $0.id == ids["rt"] }?.rect)
        let rb = try #require(layout.leaves.first { $0.id == ids["rb"] }?.rect)
        let right = rt.union(rb)
        // The inner split is confined to the right half; its divider spans
        // only that half.
        #expect(right.minX == 500 + hairline / 2)
        let inner = try #require(layout.dividers.first { $0.axis == .vertical })
        #expect(inner.rect.minX == right.minX)
        #expect(inner.rect.width == right.width)
        #expect(inner.total == bounds.height)
    }

    @Test
    func leaves_are_offset_by_the_container_origin() {
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let shifted = CGRect(x: 40, y: 20, width: 1000, height: 600)
        let layout = SplitLayout.resolve(tree, in: shifted)
        #expect(layout.leaves.first { $0.id == ids["l"] }?.rect.origin == shifted.origin)
        #expect(layout.leaves.first { $0.id == ids["r"] }?.rect.maxX == shifted.maxX)
    }

    // MARK: - Grab band

    @Test
    func band_is_centered_on_the_hairline_and_kept_inside() {
        let (tree, _) = build(H(pane("l"), pane("r"), ratio: 0.5))
        let divider = SplitLayout.resolve(tree, in: bounds).dividers[0]
        #expect(divider.bandRect.width == SplitDividerMetrics.bandThickness)
        #expect(divider.bandRect.midX == 500)
        #expect(divider.bandRect.height == bounds.height)

        let (edge, _) = build(H(pane("l"), pane("r"), ratio: 1.0))
        let clamped = SplitLayout.resolve(edge, in: bounds).dividers[0]
        #expect(clamped.bandRect.maxX == bounds.maxX)
    }

    // MARK: - Placement and slide geometry

    @Test
    func leaves_carry_the_split_that_made_them() throws {
        let (tree, ids) = build(H(pane("l"), V(pane("rt"), pane("rb"))))
        let layout = SplitLayout.resolve(tree, in: bounds)
        let l = try #require(layout.leaves.first { $0.id == ids["l"] }?.placement)
        #expect(l.axis == .horizontal)
        #expect(l.position == .first)
        #expect(l.branchRect == bounds)

        let rb = try #require(layout.leaves.first { $0.id == ids["rb"] }?.placement)
        #expect(rb.axis == .vertical)
        #expect(rb.position == .second)
        // The inner split's strip is the right half.
        #expect(rb.branchRect.minX == 500 + hairline / 2)
        #expect(rb.branchRect.maxX == bounds.maxX)
        #expect(rb.branchRect.height == bounds.height)

        let (lone, _) = build(pane("a"))
        #expect(SplitLayout.resolve(lone, in: bounds).leaves[0].placement == nil)
    }

    @Test
    func dividers_know_their_strip_and_children() throws {
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let divider = try #require(SplitLayout.resolve(tree, in: bounds).dividers.first)
        #expect(divider.branchRect == bounds)
        #expect(divider.firstID == ids["l"])
        #expect(divider.secondID == ids["r"])
    }

    @Test
    func a_right_split_grows_from_the_right_edge_of_its_strip() throws {
        // The new pane is the second of a horizontal split: collapsed against
        // the strip's right edge, zero wide, full height — so growing to its
        // tile moves its left edge exactly as the sibling's right edge moves.
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let r = try #require(SplitLayout.resolve(tree, in: bounds).leaves.first { $0.id == ids["r"] })
        let start = SplitLayout.collapsed(r.rect, placement: r.placement)
        #expect(start == CGRect(x: bounds.maxX, y: 0, width: 0, height: bounds.height))
        // Nothing to shift for a `.second` pane: the window's leading edge
        // already travels rightward.
        #expect(SplitLayout.slideOutShift(for: r.rect, placement: r.placement) == .zero)
    }

    @Test
    func a_down_split_grows_from_the_bottom_edge_of_its_strip() throws {
        let (tree, ids) = build(H(pane("l"), V(pane("rt"), pane("rb"))))
        let rb = try #require(SplitLayout.resolve(tree, in: bounds).leaves.first { $0.id == ids["rb"] })
        let start = SplitLayout.collapsed(rb.rect, placement: rb.placement)
        #expect(start.minY == bounds.maxY)
        #expect(start.height == 0)
        // Confined to the inner strip: same x extent as the tile.
        #expect(start.minX == rb.rect.minX)
        #expect(start.width == rb.rect.width)
    }

    @Test
    func a_first_pane_collapses_to_the_leading_edge_and_slides_its_content_out_through_it() throws {
        // Closing the LEFT pane: the right sibling advances leftward, so the
        // ghost's window shrinks against the strip's left edge, and the
        // content is shifted left by its own width so it leaves to the left.
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let l = try #require(SplitLayout.resolve(tree, in: bounds).leaves.first { $0.id == ids["l"] })
        #expect(SplitLayout.collapsed(l.rect, placement: l.placement) == CGRect(
            x: 0, y: 0, width: 0, height: bounds.height
        ))
        #expect(SplitLayout.slideOutShift(for: l.rect, placement: l.placement) == CGSize(
            width: -l.rect.width, height: 0
        ))

        // The TOP pane leaves upward.
        let (stacked, sids) = build(V(pane("t"), pane("b")))
        let t = try #require(SplitLayout.resolve(stacked, in: bounds).leaves.first { $0.id == sids["t"] })
        #expect(SplitLayout.collapsed(t.rect, placement: t.placement).maxY == bounds.minY)
        #expect(SplitLayout.slideOutShift(for: t.rect, placement: t.placement) == CGSize(
            width: 0, height: -t.rect.height
        ))
    }

    @Test
    func the_seam_hairline_sits_on_the_sibling_side_of_the_ghost_window() throws {
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let layout = SplitLayout.resolve(tree, in: bounds)
        let r = try #require(layout.leaves.first { $0.id == ids["r"] })
        let rPlacement = try #require(r.placement)
        // At rest the hairline is exactly where the real divider was.
        #expect(SplitLayout.seamHairline(of: r.rect, placement: rPlacement) == layout.dividers[0].rect)
        // Collapsed, it has followed the seam to the strip's edge.
        let gone = SplitLayout.collapsed(r.rect, placement: rPlacement)
        #expect(SplitLayout.seamHairline(of: gone, placement: rPlacement).maxX == bounds.maxX)

        let l = try #require(layout.leaves.first { $0.id == ids["l"] })
        let lPlacement = try #require(l.placement)
        #expect(SplitLayout.seamHairline(of: l.rect, placement: lPlacement) == layout.dividers[0].rect)

        let (stacked, sids) = build(V(pane("t"), pane("b")))
        let vlayout = SplitLayout.resolve(stacked, in: bounds)
        let b = try #require(vlayout.leaves.first { $0.id == sids["b"] })
        #expect(try SplitLayout.seamHairline(of: b.rect, placement: #require(b.placement)) == vlayout.dividers[0].rect)
    }

    @Test
    func a_lone_pane_has_no_seam_to_slide_along() {
        #expect(SplitLayout.collapsed(bounds, placement: nil) == bounds)
        #expect(SplitLayout.slideOutShift(for: bounds, placement: nil) == .zero)
    }

    // MARK: - Animation key

    @Test
    func animation_key_ignores_ratios() {
        let (tree, _) = build(H(pane("l"), pane("r"), ratio: 0.5))
        let before = SplitLayout.animationKey(of: tree, zoomedPaneID: nil)
        guard case let .split(branch) = tree else {
            Issue.record("expected a split")
            return
        }
        branch.ratio = 0.7
        #expect(SplitLayout.animationKey(of: tree, zoomedPaneID: nil) == before)
    }

    @Test
    func animation_key_tracks_structure_and_zoom() throws {
        let (tree, ids) = build(H(pane("l"), pane("r")))
        let flat = SplitLayout.animationKey(of: tree, zoomedPaneID: nil)
        #expect(SplitLayout.animationKey(of: tree, zoomedPaneID: ids["l"]) != flat)

        let (regrown, _) = try tree.splitting(
            paneID: #require(ids["r"]), direction: .vertical, position: .second, projectPath: "/", projectID: UUID()
        )
        #expect(SplitLayout.animationKey(of: regrown, zoomedPaneID: nil) != flat)
        // Same panes, opposite axis: a different layout, so a different key.
        let (vertical, _) = build(V(pane("a"), pane("b")))
        let (horizontal, _) = build(H(pane("a"), pane("b")))
        #expect(
            SplitLayout.animationKey(of: vertical, zoomedPaneID: nil).first
                != SplitLayout.animationKey(of: horizontal, zoomedPaneID: nil).first
        )
    }
}
