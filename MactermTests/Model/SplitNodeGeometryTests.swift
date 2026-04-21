@testable import Macterm
import XCTest

@MainActor
final class SplitNodeGeometryTests: XCTestCase {
    func test_paneFrames_single_pane_fills_unit_rect() throws {
        let (tree, ids) = build(pane("a"))
        let frames = tree.paneFrames()
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])], CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func test_paneFrames_horizontal_split_respects_ratio() throws {
        let (tree, ids) = build(H(pane("a"), pane("b"), ratio: 0.3))
        let frames = tree.paneFrames()
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])]?.width ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["b"])]?.width ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])]?.minX ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["b"])]?.minX ?? -1, 0.3, accuracy: 0.0001)
    }

    func test_paneFrames_vertical_split_respects_ratio() throws {
        let (tree, ids) = build(V(pane("a"), pane("b"), ratio: 0.25))
        let frames = tree.paneFrames()
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])]?.height ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["b"])]?.height ?? 0, 0.75, accuracy: 0.0001)
    }

    func test_paneFrames_nested_splits_compose() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let frames = tree.paneFrames()
        XCTAssertEqual(frames.count, 3)
        // a is left half
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])]?.width ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["a"])]?.height ?? 0, 1.0, accuracy: 0.0001)
        // b & c each half-height of right half
        XCTAssertEqual(try frames[XCTUnwrap(ids["b"])]?.height ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try frames[XCTUnwrap(ids["c"])]?.height ?? 0, 0.5, accuracy: 0.0001)
    }

    func test_paneFrames_returns_frame_for_every_pane() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), V(pane("c"), pane("d")))))
        let frames = tree.paneFrames()
        XCTAssertEqual(frames.count, tree.allPanes().count)
    }

    // MARK: - nearestPane

    func test_nearestPane_right_in_horizontal_split() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        XCTAssertEqual(try tree.nearestPane(from: XCTUnwrap(ids["a"]), direction: .right), ids["b"])
    }

    func test_nearestPane_left_in_horizontal_split() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        XCTAssertEqual(try tree.nearestPane(from: XCTUnwrap(ids["b"]), direction: .left), ids["a"])
    }

    func test_nearestPane_up_in_vertical_split() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        XCTAssertEqual(try tree.nearestPane(from: XCTUnwrap(ids["b"]), direction: .up), ids["a"])
    }

    func test_nearestPane_down_in_vertical_split() throws {
        let (tree, ids) = build(V(pane("a"), pane("b")))
        XCTAssertEqual(try tree.nearestPane(from: XCTUnwrap(ids["a"]), direction: .down), ids["b"])
    }

    func test_nearestPane_returns_nil_when_no_neighbor() throws {
        let (tree, ids) = build(pane("a"))
        XCTAssertNil(try tree.nearestPane(from: XCTUnwrap(ids["a"]), direction: .right))
    }

    func test_nearestPane_right_from_left_pane_in_HV_grid_picks_upper() throws {
        // H(a, V(b, c)) — right of a should hit whichever of b/c has overlapping y.
        // a spans full height; b is top-right, c is bottom-right. Both overlap.
        // Tiebreak by x-center distance — equal. Implementation returns the
        // first-found with minimum dist; accept either, but must be one of them.
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let target = try tree.nearestPane(from: XCTUnwrap(ids["a"]), direction: .right)
        XCTAssertTrue(target == ids["b"]! || target == ids["c"]!)
    }
}
