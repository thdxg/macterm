@testable import Macterm
import XCTest

@MainActor
final class SplitNodeTests: XCTestCase {
    // MARK: - splitting

    func test_splitting_replaces_leaf_with_branch() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: XCTUnwrap(ids["a"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        XCTAssertNotNil(newID)
        XCTAssertEqual(after.allPanes().count, 2)
        // Original pane still present.
        XCTAssertTrue(try after.contains(paneID: XCTUnwrap(ids["a"])))
    }

    func test_splitting_returns_new_pane_id_present_in_tree() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: XCTUnwrap(ids["a"]), direction: .vertical, position: .second, projectPath: "/"
        )
        XCTAssertTrue(try after.contains(paneID: XCTUnwrap(newID)))
    }

    func test_splitting_first_position_places_new_pane_on_left() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: XCTUnwrap(ids["a"]), direction: .horizontal, position: .first, projectPath: "/"
        )
        guard case let .split(b) = after, case let .pane(firstPane) = b.first else {
            return XCTFail("expected split with pane on first")
        }
        XCTAssertEqual(firstPane.id, newID)
    }

    func test_splitting_second_position_places_new_pane_on_right() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: XCTUnwrap(ids["a"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        guard case let .split(b) = after, case let .pane(secondPane) = b.second else {
            return XCTFail("expected split with pane on second")
        }
        XCTAssertEqual(secondPane.id, newID)
    }

    func test_splitting_nonexistent_pane_is_noop() {
        let (tree, _) = build(pane("a"))
        let (after, newID) = tree.splitting(
            paneID: UUID(), direction: .horizontal, position: .second, projectPath: "/"
        )
        XCTAssertNil(newID)
        XCTAssertEqual(after.allPanes().count, 1)
    }

    func test_splitting_deep_preserves_other_panes() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let beforeIDs = Set(tree.allPanes().map(\.id))
        let (after, newID) = try tree.splitting(
            paneID: XCTUnwrap(ids["b"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        let afterIDs = Set(after.allPanes().map(\.id))
        // Every original pane still present + one new.
        XCTAssertTrue(beforeIDs.isSubset(of: afterIDs))
        XCTAssertEqual(afterIDs.count, beforeIDs.count + 1)
        XCTAssertTrue(try afterIDs.contains(XCTUnwrap(newID)))
    }

    // MARK: - removing

    func test_removing_only_pane_returns_nil() throws {
        let (tree, ids) = build(pane("a"))
        XCTAssertNil(try tree.removing(paneID: XCTUnwrap(ids["a"])))
    }

    func test_removing_leaf_from_simple_split_collapses_to_sibling() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.removing(paneID: XCTUnwrap(ids["a"]))
        XCTAssertEqual(try render(XCTUnwrap(after), ids: ids), "b")
    }

    func test_removing_nonexistent_leaves_tree_unchanged() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = tree.removing(paneID: UUID())
        XCTAssertEqual(try render(XCTUnwrap(after), ids: ids), "H(a, b)")
    }

    /// Regression for the HV-close bug (user report): `H(l1, V(r1, r2))`, remove
    /// `l1` → must become `V(r1, r2)` with the original `r1` and `r2` panes
    /// intact. The bug previously caused `r1` to be replaced by a fresh pane.
    func test_removing_first_pane_in_HV_split_preserves_other_panes() throws {
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        let after = try tree.removing(paneID: XCTUnwrap(ids["l1"]))
        XCTAssertEqual(try render(XCTUnwrap(after), ids: ids), "V(r1, r2)")
        // Identity preserved: r1 and r2 still reference the original panes.
        let remaining = try Set(XCTUnwrap(after?.allPanes().map(\.id)))
        XCTAssertEqual(remaining, try [XCTUnwrap(ids["r1"]), XCTUnwrap(ids["r2"])])
    }

    func test_removing_deep_leaf_preserves_siblings() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let after = try tree.removing(paneID: XCTUnwrap(ids["c"]))
        XCTAssertEqual(try render(XCTUnwrap(after), ids: ids), "H(a, b)")
    }

    // MARK: - findPane / contains / allPanes

    func test_findPane_returns_same_instance() {
        let p = Pane(projectPath: "/")
        let tree: SplitNode = .split(SplitBranch(direction: .horizontal, first: .pane(p), second: .pane(Pane(projectPath: "/"))))
        XCTAssertTrue(tree.findPane(id: p.id) === p)
    }

    func test_findPane_returns_nil_for_missing() {
        let (tree, _) = build(pane("a"))
        XCTAssertNil(tree.findPane(id: UUID()))
    }

    func test_contains_matches_allPanes() {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let all = Set(tree.allPanes().map(\.id))
        for (_, id) in ids {
            XCTAssertTrue(tree.contains(paneID: id))
            XCTAssertTrue(all.contains(id))
        }
        XCTAssertFalse(tree.contains(paneID: UUID()))
    }

    func test_allPanes_count_matches_leaf_count() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), V(pane("c"), pane("d")))))
        XCTAssertEqual(tree.allPanes().count, 4)
    }
}
