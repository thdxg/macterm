import Foundation
@testable import Macterm
import Testing

@MainActor
struct SplitNodeResizeTests {
    private func ratio(_ node: SplitNode) -> CGFloat? {
        if case let .split(b) = node { return b.ratio }
        return nil
    }

    private func firstBranch(_ node: SplitNode) -> SplitBranch? {
        if case let .split(b) = node { return b }
        return nil
    }

    @Test
    func resize_right_adjusts_horizontal_ancestor() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .right, delta: 0.1)
        #expect(abs((ratio(after) ?? -1) - 0.6) < 0.0001)
    }

    @Test
    func resize_left_decreases_horizontal_ancestor_ratio() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .left, delta: 0.1)
        #expect(abs((ratio(after) ?? -1) - 0.4) < 0.0001)
    }

    @Test
    func resize_down_adjusts_vertical_ancestor() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .down, delta: 0.1)
        #expect(abs((ratio(after) ?? -1) - 0.6) < 0.0001)
    }

    @Test
    func resize_skips_non_matching_axis_ancestors() throws {
        // Outer H, inner V containing the focused pane.
        let (tree, ids) = build(H(pane("a"), V(pane("b1"), pane("b2"))))
        let after = try tree.resizing(paneID: #require(ids["b1"]), direction: .right, delta: 0.1)
        #expect(abs((ratio(after) ?? -1) - 0.6) < 0.0001)
        if case let .split(b) = after, case let .split(inner) = b.second {
            #expect(abs(inner.ratio - 0.5) < 0.0001)
        } else {
            Issue.record("expected inner V preserved")
        }
    }

    @Test
    func resize_clamps_to_upper_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .right, delta: 10.0)
        #expect(abs((ratio(after) ?? -1) - 0.85) < 0.0001)
    }

    @Test
    func resize_clamps_to_lower_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .left, delta: 10.0)
        #expect(abs((ratio(after) ?? -1) - 0.15) < 0.0001)
    }

    @Test
    func resize_on_root_leaf_is_noop() throws {
        let (tree, ids) = build(pane("a"))
        let after = try tree.resizing(paneID: #require(ids["a"]), direction: .right, delta: 0.1)
        #expect(firstBranch(after) == nil)
        #expect(after.allPanes().count == 1)
    }

    @Test
    func resize_picks_deepest_matching_ancestor() throws {
        // Nested H-in-H — deeper ancestor wins.
        let (tree, ids) = build(H(pane("a"), H(pane("b"), pane("c"))))
        let after = try tree.resizing(paneID: #require(ids["b"]), direction: .right, delta: 0.1)
        #expect(abs((ratio(after) ?? -1) - 0.5) < 0.0001)
        if case let .split(b) = after, case let .split(inner) = b.second {
            #expect(abs(inner.ratio - 0.6) < 0.0001)
        } else {
            Issue.record("expected inner H preserved")
        }
    }
}
