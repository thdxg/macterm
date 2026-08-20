import Foundation
@testable import Macterm
import Testing

/// The seam a join lands on. These pin the two ends especially: they are the
/// positions a user aims at most and the ones an off-by-one loses first.
@MainActor
struct TabMergePlacementTests {
    // MARK: - Which seam

    /// Rounding to the nearest boundary, not flooring into a segment: with
    /// flooring the last boundary is unreachable, and "after the last pane" is
    /// the commonest intent there is.
    @Test
    func the_far_edges_are_reachable() {
        #expect(TabMergePlacement.insertionIndex(x: 0, width: 300, paneCount: 3) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 300, width: 300, paneCount: 3) == 3)
    }

    @Test
    func the_nearest_seam_wins() {
        // Three panes across 300pt: seams at 0, 100, 200, 300.
        #expect(TabMergePlacement.insertionIndex(x: 40, width: 300, paneCount: 3) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 60, width: 300, paneCount: 3) == 1)
        #expect(TabMergePlacement.insertionIndex(x: 149, width: 300, paneCount: 3) == 1)
        #expect(TabMergePlacement.insertionIndex(x: 151, width: 300, paneCount: 3) == 2)
    }

    /// A single-pane tab still offers both sides: before it or after it.
    @Test
    func a_single_pane_row_still_has_two_sides() {
        #expect(TabMergePlacement.insertionIndex(x: 10, width: 200, paneCount: 1) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 190, width: 200, paneCount: 1) == 1)
    }

    @Test
    func a_pointer_past_the_edges_clamps() {
        #expect(TabMergePlacement.insertionIndex(x: -50, width: 300, paneCount: 3) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 900, width: 300, paneCount: 3) == 3)
    }

    /// A row mid-teardown can report zero width or no panes; neither may
    /// produce a NaN or a negative index.
    @Test
    func degenerate_geometry_is_survivable() {
        #expect(TabMergePlacement.insertionIndex(x: 10, width: 0, paneCount: 3) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 10, width: 300, paneCount: 0) == 0)
    }

    // MARK: - Which target

    @Test
    func the_first_seam_lands_left_of_the_first_pane() {
        let panes = [UUID(), UUID(), UUID()]
        #expect(TabMergePlacement.target(insertionIndex: 0, panes: panes) == .pane(panes[0], .left))
    }

    @Test
    func the_last_seam_lands_right_of_the_last_pane() {
        let panes = [UUID(), UUID(), UUID()]
        #expect(TabMergePlacement.target(insertionIndex: 3, panes: panes) == .pane(panes[2], .right))
    }

    /// An interior seam is expressed as "right of the pane before it" — the
    /// same place as "left of the pane after it", stated one way so the two
    /// can't disagree.
    @Test
    func an_interior_seam_lands_between_its_two_panes() {
        let panes = [UUID(), UUID(), UUID()]
        #expect(TabMergePlacement.target(insertionIndex: 1, panes: panes) == .pane(panes[0], .right))
        #expect(TabMergePlacement.target(insertionIndex: 2, panes: panes) == .pane(panes[1], .right))
    }

    /// Every seam must be a LOCAL split beside a named pane. A whole-edge drop
    /// would land beside the entire tree, making every seam mean the same
    /// thing — which is the behavior this placement replaced.
    @Test
    func no_seam_resolves_to_a_root_edge() {
        let panes = [UUID(), UUID()]
        for index in 0 ... panes.count {
            switch TabMergePlacement.target(insertionIndex: index, panes: panes) {
            case .rootEdge,
                 .divider,
                 .none:
                Issue.record("seam \(index) did not resolve to a local pane split")
            case .pane:
                break
            }
        }
    }

    @Test
    func an_empty_tab_has_no_target() {
        #expect(TabMergePlacement.target(insertionIndex: 0, panes: []) == nil)
    }
}
