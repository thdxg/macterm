import Foundation
@testable import Macterm
import Testing

@MainActor
struct SplitNodeTests {
    // MARK: - splitting

    @Test
    func splitting_replaces_leaf_with_branch() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: #require(ids["a"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        #expect(newID != nil)
        #expect(after.allPanes().count == 2)
        #expect(try after.contains(paneID: #require(ids["a"])))
    }

    @Test
    func splitting_returns_new_pane_id_present_in_tree() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: #require(ids["a"]), direction: .vertical, position: .second, projectPath: "/"
        )
        #expect(try after.contains(paneID: #require(newID)))
    }

    @Test
    func splitting_first_position_places_new_pane_on_left() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: #require(ids["a"]), direction: .horizontal, position: .first, projectPath: "/"
        )
        guard case let .split(b) = after, case let .pane(firstPane) = b.first else {
            Issue.record("expected split with pane on first")
            return
        }
        #expect(firstPane.id == newID)
    }

    @Test
    func splitting_second_position_places_new_pane_on_right() throws {
        let (tree, ids) = build(pane("a"))
        let (after, newID) = try tree.splitting(
            paneID: #require(ids["a"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        guard case let .split(b) = after, case let .pane(secondPane) = b.second else {
            Issue.record("expected split with pane on second")
            return
        }
        #expect(secondPane.id == newID)
    }

    @Test
    func splitting_nonexistent_pane_is_noop() {
        let (tree, _) = build(pane("a"))
        let (after, newID) = tree.splitting(
            paneID: UUID(), direction: .horizontal, position: .second, projectPath: "/"
        )
        #expect(newID == nil)
        #expect(after.allPanes().count == 1)
    }

    @Test
    func splitting_deep_preserves_other_panes() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let beforeIDs = Set(tree.allPanes().map(\.id))
        let (after, newID) = try tree.splitting(
            paneID: #require(ids["b"]), direction: .horizontal, position: .second, projectPath: "/"
        )
        let afterIDs = Set(after.allPanes().map(\.id))
        #expect(beforeIDs.isSubset(of: afterIDs))
        #expect(afterIDs.count == beforeIDs.count + 1)
        #expect(try afterIDs.contains(#require(newID)))
    }

    // MARK: - removing

    @Test
    func removing_only_pane_returns_nil() throws {
        let (tree, ids) = build(pane("a"))
        #expect(try tree.removing(paneID: #require(ids["a"])) == nil)
    }

    @Test
    func removing_leaf_from_simple_split_collapses_to_sibling() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = try tree.removing(paneID: #require(ids["a"]))
        #expect(try render(#require(after), ids: ids) == "b")
    }

    @Test
    func removing_nonexistent_leaves_tree_unchanged() throws {
        let (tree, ids) = build(H(pane("a"), pane("b")))
        let after = tree.removing(paneID: UUID())
        #expect(try render(#require(after), ids: ids) == "H(a, b)")
    }

    /// Regression for the HV-close bug (user report): `H(l1, V(r1, r2))`, remove
    /// `l1` → must become `V(r1, r2)` with the original `r1` and `r2` panes
    /// intact. The bug previously caused `r1` to be replaced by a fresh pane.
    @Test
    func removing_first_pane_in_HV_split_preserves_other_panes() throws {
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        let after = try tree.removing(paneID: #require(ids["l1"]))
        #expect(try render(#require(after), ids: ids) == "V(r1, r2)")
        let remaining = try Set(#require(after?.allPanes().map(\.id)))
        #expect(try remaining == [#require(ids["r1"]), #require(ids["r2"])])
    }

    @Test
    func removing_deep_leaf_preserves_siblings() throws {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let after = try tree.removing(paneID: #require(ids["c"]))
        #expect(try render(#require(after), ids: ids) == "H(a, b)")
    }

    // MARK: - findPane / contains / allPanes

    @Test
    func findPane_returns_same_instance() {
        let p = Pane(projectPath: "/")
        let tree: SplitNode = .split(SplitBranch(direction: .horizontal, first: .pane(p), second: .pane(Pane(projectPath: "/"))))
        #expect(tree.findPane(id: p.id) === p)
    }

    @Test
    func findPane_returns_nil_for_missing() {
        let (tree, _) = build(pane("a"))
        #expect(tree.findPane(id: UUID()) == nil)
    }

    @Test
    func contains_matches_allPanes() {
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        let all = Set(tree.allPanes().map(\.id))
        for (_, id) in ids {
            #expect(tree.contains(paneID: id))
            #expect(all.contains(id))
        }
        #expect(!tree.contains(paneID: UUID()))
    }

    @Test
    func allPanes_count_matches_leaf_count() {
        let (tree, _) = build(H(pane("a"), H(pane("b"), V(pane("c"), pane("d")))))
        #expect(tree.allPanes().count == 4)
    }
}
