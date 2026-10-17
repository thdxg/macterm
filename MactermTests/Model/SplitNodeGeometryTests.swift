import Foundation
@testable import Macterm
import Testing

@MainActor
struct SplitNodeGeometryTests {
    @Test
    func paneFrames_single_pane_fills_unit_rect() throws {
        let (tree, ids) = build(pane("a"))
        let frames = tree.paneFrames()
        #expect(try frames[#require(ids["a"])] == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test
    func paneFrames_horizontal_split_respects_ratio() throws {
        let (tree, ids) = build(H(pane("a"), pane("b"), ratio: 0.3))
        let frames = tree.paneFrames()
        #expect(try abs((frames[#require(ids["a"])]?.width ?? 0) - 0.3) < 0.0001)
        #expect(try abs((frames[#require(ids["b"])]?.width ?? 0) - 0.7) < 0.0001)
        #expect(try abs((frames[#require(ids["a"])]?.minX ?? -1) - 0) < 0.0001)
        #expect(try abs((frames[#require(ids["b"])]?.minX ?? -1) - 0.3) < 0.0001)
    }

    @Test
    func paneFrames_vertical_split_respects_ratio() throws {
        let (tree, ids) = build(V(pane("a"), pane("b"), ratio: 0.25))
        let frames = tree.paneFrames()
        #expect(try abs((frames[#require(ids["a"])]?.height ?? 0) - 0.25) < 0.0001)
        #expect(try abs((frames[#require(ids["b"])]?.height ?? 0) - 0.75) < 0.0001)
    }

    @Test
    func paneFrames_nested_splits_compose() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let frames = tree.paneFrames()
        #expect(frames.count == 3)
        #expect(try abs((frames[#require(ids["a"])]?.width ?? 0) - 0.5) < 0.0001)
        #expect(try abs((frames[#require(ids["a"])]?.height ?? 0) - 1.0) < 0.0001)
        #expect(try abs((frames[#require(ids["b"])]?.height ?? 0) - 0.5) < 0.0001)
        #expect(try abs((frames[#require(ids["c"])]?.height ?? 0) - 0.5) < 0.0001)
    }

    @Test
    func paneFrames_returns_frame_for_every_pane() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), V(pane("c"), pane("d")))))
        let frames = tree.paneFrames()
        #expect(frames.count == tree.allPanes().count)
    }

    // MARK: - nearestPane

    @Test
    func nearestPane_right_in_horizontal_split() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        #expect(try tree.nearestPane(from: #require(ids["a"]), direction: .right) == ids["b"])
    }

    @Test
    func nearestPane_left_in_horizontal_split() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        #expect(try tree.nearestPane(from: #require(ids["b"]), direction: .left) == ids["a"])
    }

    @Test
    func nearestPane_up_in_vertical_split() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        #expect(try tree.nearestPane(from: #require(ids["b"]), direction: .up) == ids["a"])
    }

    @Test
    func nearestPane_down_in_vertical_split() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        #expect(try tree.nearestPane(from: #require(ids["a"]), direction: .down) == ids["b"])
    }

    @Test
    func nearestPane_returns_nil_when_no_neighbor() throws {
        let (tree, ids) = build(pane("a"))
        #expect(try tree.nearestPane(from: #require(ids["a"]), direction: .right) == nil)
    }

    @Test
    func nearestPane_right_from_left_pane_in_HV_grid_picks_upper() throws {
        // b and c are the same distance away: the tie goes to tree order, the
        // same answer every run (Move Pane swaps with this pane).
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        for _ in 0 ..< 20 {
            #expect(try tree.nearestPane(from: #require(ids["a"]), direction: .right) == ids["b"])
        }
    }

    // MARK: - swappingPanes

    @Test
    func swappingPanes_trades_two_leaves_and_keeps_shape_and_ratios() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"), ratio: 0.3), ratio: 0.6))
        let swapped = try tree.swappingPanes(#require(ids["a"]), #require(ids["c"]))
        #expect(swapped.allPanes().map(\.id) == [ids["c"], ids["b"], ids["a"]])
        guard case let .split(root) = swapped, case let .split(inner) = root.second else {
            Issue.record("shape changed")
            return
        }
        #expect(root.direction == .horizontal && root.ratio == 0.6)
        #expect(inner.direction == .vertical && inner.ratio == 0.3)
    }

    @Test
    func swappingPanes_with_an_unknown_pane_is_a_noop() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let swapped = try tree.swappingPanes(#require(ids["a"]), UUID())
        #expect(swapped.allPanes().map(\.id) == [ids["a"], ids["b"]])
    }
}
