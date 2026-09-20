import CoreGraphics
@testable import Macterm
import Testing

/// The flat geometry `AnimatedSplitView` renders (Settings → Animations →
/// Animate splits). UI behaviour isn't unit-tested per the project's
/// conventions, but the rectangles are plain arithmetic worth pinning: they
/// must match the nested frames `SplitDividerView` lays out, so toggling the
/// setting moves no pane, and the animation key must ignore ratios so a
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

    /// A divider outliving its branch keeps its thickness and travels to the
    /// seam, so it arrives on top of the divider coming the other way rather
    /// than blinking out where the boundary no longer is.
    @Test
    func a_divider_whose_branch_collapsed_travels_to_the_merged_seam() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let before: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1000, height: 200),
            b: CGRect(x: 0, y: 201, width: 1000, height: 199),
            c: CGRect(x: 0, y: 401, width: 1000, height: 199),
        ]
        let after: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1000, height: 299.5),
            c: CGRect(x: 0, y: 300.5, width: 1000, height: 299.5),
        ]
        // The divider under the closed tile: its own neighbour above is the
        // tile that left, so the survivor below is what tells it where to go.
        let dying = CGRect(x: 0, y: 400, width: 1000, height: hairline)
        let seam = try #require(SplitLayout.closingSeam(
            of: dying, axis: .vertical, before: before, after: after
        ))
        let moved = SplitLayout.moved(dying, axis: .vertical, onto: seam)
        #expect(moved.height == hairline)
        #expect(moved.width == dying.width)
        // Within half a point of where the surviving divider settles.
        #expect(abs(moved.midY - 300) <= hairline / 2)
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

    // MARK: - Closing seam

    /// Three stacked panes, auto-tiling on: closing the middle one rebalances
    /// the survivors to half each, so the divider above the closed tile and
    /// the divider below it both travel to the same line between them. The
    /// ghost's strip has to collapse there, not onto the branch edge it
    /// grew from — that dragged its hairline back across the pane above.
    @Test
    func closing_seam_merges_both_neighbours_when_a_rebalance_moves_them() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let before: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1000, height: 200),
            b: CGRect(x: 0, y: 201, width: 1000, height: 199),
            c: CGRect(x: 0, y: 401, width: 1000, height: 199),
        ]
        let after: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1000, height: 299.5),
            c: CGRect(x: 0, y: 300.5, width: 1000, height: 299.5),
        ]
        let closing = try #require(before[b])
        let seam = try #require(SplitLayout.closingSeam(
            of: closing, axis: .vertical, before: before, after: after
        ))
        #expect(seam == 300)
        // Both hairlines travel the same distance to reach it.
        #expect(abs(seam - 200) == abs(seam - 400))
    }

    /// Two panes: the survivor takes the whole container, so the seam is the
    /// container edge — the same answer `collapsed` gives from the branch.
    @Test
    func closing_seam_is_the_container_edge_when_one_sibling_reclaims() throws {
        let top = UUID(), bottom = UUID()
        let before: [UUID: CGRect] = [
            top: CGRect(x: 0, y: 0, width: 1000, height: 299.5),
            bottom: CGRect(x: 0, y: 300.5, width: 1000, height: 299.5),
        ]
        let after: [UUID: CGRect] = [top: bounds]
        let closing = try #require(before[bottom])
        let seam = try #require(SplitLayout.closingSeam(
            of: closing, axis: .vertical, before: before, after: after
        ))
        #expect(seam == bounds.maxY)
        #expect(
            SplitLayout.collapsed(closing, axis: .vertical, onto: seam)
                == CGRect(x: 0, y: bounds.maxY, width: 1000, height: 0)
        )
    }

    /// A tile that shares no edge with a survivor (the last pane of a tab,
    /// or a tree rebuilt wholesale) has nothing to converge on.
    @Test
    func closing_seam_is_nil_without_a_surviving_neighbour() {
        let only = UUID()
        let before: [UUID: CGRect] = [only: bounds]
        #expect(SplitLayout.closingSeam(of: bounds, axis: .vertical, before: before, after: [:]) == nil)
    }

    /// Side-by-side panes read their edges along x, and a neighbour that
    /// doesn't overlap the closing tile's rows isn't one.
    @Test
    func closing_seam_reads_the_axis_and_ignores_non_overlapping_tiles() throws {
        let left = UUID(), right = UUID(), elsewhere = UUID()
        let closing = CGRect(x: 300, y: 0, width: 200, height: 600)
        let before: [UUID: CGRect] = [
            left: CGRect(x: 0, y: 0, width: 299, height: 600),
            right: CGRect(x: 501, y: 0, width: 499, height: 600),
            // Sits against the closing tile's left edge but in other rows.
            elsewhere: CGRect(x: 0, y: 700, width: 299, height: 100),
        ]
        let after: [UUID: CGRect] = [
            left: CGRect(x: 0, y: 0, width: 499.5, height: 600),
            right: CGRect(x: 500.5, y: 0, width: 499.5, height: 600),
            elsewhere: CGRect(x: 0, y: 700, width: 299, height: 100),
        ]
        let seam = try #require(SplitLayout.closingSeam(
            of: closing, axis: .horizontal, before: before, after: after
        ))
        #expect(seam == 500)
    }
}
