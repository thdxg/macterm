import Foundation
@testable import Macterm
import Testing

/// Pins the Ghostty-mirror drop algorithm: a drag resolves purely LOCALLY to
/// the hovered pane — its four triangular edge zones pick the closest edge
/// and the preview is that pane's half. Never a root-edge or divider target:
/// the old workspace bands could show two different overlays for the same
/// final tree (H(a,b) with a in hand: a full-width top strip and b's top
/// half both produced V(a,b)).
@MainActor
struct TabDropPlacementTests {
    private func twoColumns() -> (SplitNode, [String: UUID]) {
        build(H(pane("a"), pane("b")))
    }

    // MARK: - Triangular zones (relative to the hovered pane)

    @Test
    func top_zone_of_a_pane_previews_that_panes_top_half() throws {
        let (root, ids) = twoColumns()
        // Top-center of pane b — the user-visible case that used to also be
        // reachable as a full-width rootEdge strip.
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.75, y: 0.1), in: root))
        #expect(try r.target == .pane(#require(ids["b"]), .top))
        #expect(r.preview == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test
    func zones_are_relative_to_the_pane_not_the_workspace() throws {
        // Pane a spans x 0..0.5; its zone triangles normalize to ITS size, so
        // x=0.45 (90% across the pane) is the right zone even though it sits
        // left of the workspace midline.
        let (root, ids) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.45, y: 0.5), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .right))
        #expect(r.preview == CGRect(x: 0.25, y: 0, width: 0.25, height: 1))
    }

    @Test
    func corner_and_center_ties_break_left_then_right_like_ghostty() throws {
        // Ghostty's check order is left → right → top → bottom; corners and
        // the exact center resolve to a horizontal zone, never top/bottom.
        let (root, ids) = build(pane("a"))
        let a = try #require(ids["a"])
        #expect(try #require(TabDropPlacer.resolve(point: .zero, in: root)).target == .pane(a, .left))
        #expect(try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.5, y: 0.5), in: root)).target == .pane(a, .left))
        #expect(try #require(TabDropPlacer.resolve(point: CGPoint(x: 1, y: 1), in: root)).target == .pane(a, .right))
    }

    @Test
    func single_pane_root_splits_locally() throws {
        let (root, ids) = build(pane("a"))
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.02, y: 0.5), in: root))
        #expect(try r.target == .pane(#require(ids["a"]), .left))
        #expect(r.preview == CGRect(x: 0, y: 0, width: 0.5, height: 1))
    }

    @Test
    func nested_pane_resolves_within_its_own_frame() throws {
        // Right column split vertically; near b's bottom edge — the old
        // algorithm escalated this to the b/c divider.
        let (root, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 0.75, y: 0.45), in: root))
        #expect(try r.target == .pane(#require(ids["b"]), .bottom))
        #expect(r.preview == CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.25))
    }

    @Test
    func out_of_range_points_clamp_into_the_nearest_pane() throws {
        let (root, ids) = twoColumns()
        let r = try #require(TabDropPlacer.resolve(point: CGPoint(x: 1.2, y: 0.5), in: root))
        #expect(try r.target == .pane(#require(ids["b"]), .right))
    }

    // MARK: - No escalation, no duplicate outcomes

    @Test
    func every_point_resolves_to_the_hovered_panes_half_and_nothing_else() throws {
        // Sweep a grid over two tree shapes: the target is always a local
        // pane split whose preview is exactly half the hovered pane — the
        // property that makes one final state reachable by one overlay only.
        let trees = [twoColumns(), build(H(pane("a"), V(pane("b"), pane("c"))))]
        for (root, _) in trees {
            let frames = root.paneFrames()
            for xi in 0 ... 20 {
                for yi in 0 ... 20 {
                    let point = CGPoint(x: CGFloat(xi) / 20, y: CGFloat(yi) / 20)
                    let r = try #require(TabDropPlacer.resolve(point: point, in: root))
                    guard case let .pane(paneID, zone) = r.target else {
                        Issue.record("non-local target \(r.target) at \(point)")
                        return
                    }
                    let frame = try #require(frames[paneID])
                    let half = zone.splitDirection == .horizontal
                        ? frame.width / 2
                        : frame.height / 2
                    let extent = zone.splitDirection == .horizontal ? r.preview.width : r.preview.height
                    #expect(abs(extent - half) < 0.0001)
                    #expect(frame.insetBy(dx: -0.0001, dy: -0.0001).contains(r.preview))
                }
            }
        }
    }
}
