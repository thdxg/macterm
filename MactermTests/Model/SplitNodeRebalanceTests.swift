import Foundation
@testable import Macterm
import Testing

@MainActor
struct SplitNodeRebalanceTests {
    private func ratio(_ node: SplitNode) -> CGFloat? {
        if case let .split(b) = node { return b.ratio }
        return nil
    }

    @Test
    func rebalance_simple_split_sets_5050() {
        let (tree, _) = build(H(pane("a"), pane("b"), ratio: 0.2))
        let after = tree.rebalanced()
        #expect(abs((ratio(after) ?? -1) - 0.5) < 0.0001)
    }

    @Test
    func rebalance_three_same_axis_panes_gives_thirds() {
        // H(a, H(b, c)) — outer should be 1/3, inner 1/2.
        let (tree, _) = build(H(pane("a"), H(pane("b"), pane("c"))))
        let after = tree.rebalanced()
        #expect(abs((ratio(after) ?? -1) - (1.0 / 3.0)) < 0.0001)
        if case let .split(b) = after, case let .split(inner) = b.second {
            #expect(abs(inner.ratio - 0.5) < 0.0001)
        } else {
            Issue.record("expected inner H preserved")
        }
    }

    @Test
    func rebalance_different_axis_descendants_count_as_one_cell() {
        // H(a, V(b, c)) — outer should stay ~0.5 because the V subtree counts
        // as a single cell along the horizontal direction.
        let (tree, _) = build(H(pane("a"), V(pane("b"), pane("c")), ratio: 0.2))
        let after = tree.rebalanced()
        #expect(abs((ratio(after) ?? -1) - 0.5) < 0.0001)
    }

    @Test
    func rebalance_is_idempotent() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), pane("c")), ratio: 0.9))
        let once = tree.rebalanced()
        let r1 = ratio(once) ?? -1
        let twice = once.rebalanced()
        let r2 = ratio(twice) ?? -2
        #expect(abs(r1 - r2) < 0.0001)
    }

    @Test
    func rebalance_leaf_is_noop() {
        let (tree, _) = build(pane("a"))
        let after = tree.rebalanced()
        #expect(after.allPanes().count == 1)
    }
}
