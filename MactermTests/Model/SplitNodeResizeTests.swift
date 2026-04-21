@testable import Macterm
import XCTest

@MainActor
final class SplitNodeResizeTests: XCTestCase {
    private func ratio(_ node: SplitNode) -> CGFloat? {
        if case let .split(b) = node { return b.ratio }
        return nil
    }

    private func firstBranch(_ node: SplitNode) -> SplitBranch? {
        if case let .split(b) = node { return b }
        return nil
    }

    func test_resize_right_adjusts_horizontal_ancestor() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .right, delta: 0.1)
        XCTAssertEqual(ratio(after) ?? -1, 0.6, accuracy: 0.0001)
    }

    func test_resize_left_decreases_horizontal_ancestor_ratio() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .left, delta: 0.1)
        XCTAssertEqual(ratio(after) ?? -1, 0.4, accuracy: 0.0001)
    }

    func test_resize_down_adjusts_vertical_ancestor() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .down, delta: 0.1)
        XCTAssertEqual(ratio(after) ?? -1, 0.6, accuracy: 0.0001)
    }

    func test_resize_skips_non_matching_axis_ancestors() throws {
        // Outer H, inner V containing the focused pane.
        // Resizing .right from b1 should walk past the inner V and adjust the outer H.
        let (tree, ids) = build(H(pane("a"), V(pane("b1"), pane("b2"))))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["b1"]), direction: .right, delta: 0.1)
        // Outer H was 0.5; resize-right on a pane in the second child moves outer ratio up.
        XCTAssertEqual(ratio(after) ?? -1, 0.6, accuracy: 0.0001)
        // Inner V ratio untouched.
        if case let .split(b) = after, case let .split(inner) = b.second {
            XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.0001)
        } else {
            XCTFail("expected inner V preserved")
        }
    }

    func test_resize_clamps_to_upper_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .right, delta: 10.0)
        XCTAssertEqual(ratio(after) ?? -1, 0.85, accuracy: 0.0001)
    }

    func test_resize_clamps_to_lower_bound() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .left, delta: 10.0)
        XCTAssertEqual(ratio(after) ?? -1, 0.15, accuracy: 0.0001)
    }

    func test_resize_on_root_leaf_is_noop() throws {
        let (tree, ids) = build(pane("a"))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["a"]), direction: .right, delta: 0.1)
        // Still a leaf.
        XCTAssertNil(firstBranch(after))
        XCTAssertEqual(after.allPanes().count, 1)
    }

    func test_resize_picks_deepest_matching_ancestor() throws {
        // Nested H-in-H — deeper ancestor wins.
        let (tree, ids) = build(H(pane("a"), H(pane("b"), pane("c"))))
        let after = try tree.resizing(paneID: XCTUnwrap(ids["b"]), direction: .right, delta: 0.1)
        // Outer ratio unchanged, inner ratio bumped.
        XCTAssertEqual(ratio(after) ?? -1, 0.5, accuracy: 0.0001)
        if case let .split(b) = after, case let .split(inner) = b.second {
            XCTAssertEqual(inner.ratio, 0.6, accuracy: 0.0001)
        } else {
            XCTFail("expected inner H preserved")
        }
    }
}
