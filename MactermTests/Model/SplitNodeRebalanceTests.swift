@testable import Macterm
import XCTest

@MainActor
final class SplitNodeRebalanceTests: XCTestCase {
    private func ratio(_ node: SplitNode) -> CGFloat? {
        if case let .split(b) = node { return b.ratio }
        return nil
    }

    func test_rebalance_simple_split_sets_5050() {
        let (tree, _) = build(H(pane("a"), pane("b"), ratio: 0.2))
        let after = tree.rebalanced()
        XCTAssertEqual(ratio(after) ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_rebalance_three_same_axis_panes_gives_thirds() {
        // H(a, H(b, c)) — outer should be 1/3, inner 1/2.
        let (tree, _) = build(H(pane("a"), H(pane("b"), pane("c"))))
        let after = tree.rebalanced()
        XCTAssertEqual(ratio(after) ?? -1, 1.0 / 3.0, accuracy: 0.0001)
        if case let .split(b) = after, case let .split(inner) = b.second {
            XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.0001)
        } else {
            XCTFail("expected inner H preserved")
        }
    }

    func test_rebalance_different_axis_descendants_count_as_one_cell() {
        // H(a, V(b, c)) — outer should stay ~0.5 because the V subtree counts
        // as a single cell along the horizontal direction.
        let (tree, _) = build(H(pane("a"), V(pane("b"), pane("c")), ratio: 0.2))
        let after = tree.rebalanced()
        XCTAssertEqual(ratio(after) ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_rebalance_is_idempotent() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), pane("c")), ratio: 0.9))
        let once = tree.rebalanced()
        let r1 = ratio(once) ?? -1
        let twice = once.rebalanced()
        let r2 = ratio(twice) ?? -2
        XCTAssertEqual(r1, r2, accuracy: 0.0001)
    }

    func test_rebalance_leaf_is_noop() {
        let (tree, _) = build(pane("a"))
        let after = tree.rebalanced()
        XCTAssertEqual(after.allPanes().count, 1)
    }
}
