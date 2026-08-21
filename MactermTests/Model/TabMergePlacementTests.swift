import Foundation
@testable import Macterm
import Testing

/// The seam a join lands on. These pin the two ends especially: they are the
/// positions a user aims at most and the ones an off-by-one loses first.
@MainActor
struct TabMergePlacementTests {
    // MARK: - Where the seams are

    /// Interior seams sit at the MIDPOINT of the gap between two segments,
    /// because that is where the row draws its divider. Even fractions of the
    /// row width land a few points beside it, which is visible when the whole
    /// point is to line up with the `|` the user is aiming at.
    @Test
    func interior_seams_sit_on_the_divider_between_segments() {
        let frames = [
            CGRect(x: 0, y: 0, width: 90, height: 20),
            CGRect(x: 100, y: 0, width: 90, height: 20),
        ]
        #expect(TabMergePlacement.seams(segmentFrames: frames) == [0, 95, 190])
    }

    @Test
    func seams_are_ordered_even_when_the_frames_arrive_unordered() {
        // Preference collection makes no ordering promise.
        let frames = [
            CGRect(x: 100, y: 0, width: 90, height: 20),
            CGRect(x: 0, y: 0, width: 90, height: 20),
        ]
        #expect(TabMergePlacement.seams(segmentFrames: frames) == [0, 95, 190])
    }

    /// A row that drew no dividers has no seam to offer: its title is one
    /// piece, or it collapsed to a pane count. The caller falls back to
    /// appending at the trailing edge rather than inventing a position.
    @Test
    func a_row_without_segments_has_no_seams() {
        #expect(TabMergePlacement.seams(segmentFrames: []).isEmpty)
        #expect(TabMergePlacement.seams(segmentFrames: [CGRect(x: 0, y: 0, width: 90, height: 20)]).isEmpty)
    }

    // MARK: - Which seam

    /// Nearest seam, not "the segment x falls into": falling-in can never
    /// choose the last seam, and "after everything" is the commonest intent.
    @Test
    func the_far_edges_are_reachable() {
        let seams: [CGFloat] = [0, 95, 190]
        #expect(TabMergePlacement.insertionIndex(x: 0, seams: seams) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 190, seams: seams) == 2)
    }

    @Test
    func the_nearest_seam_wins() {
        let seams: [CGFloat] = [0, 95, 190]
        #expect(TabMergePlacement.insertionIndex(x: 40, seams: seams) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 60, seams: seams) == 1)
        #expect(TabMergePlacement.insertionIndex(x: 140, seams: seams) == 1)
        #expect(TabMergePlacement.insertionIndex(x: 150, seams: seams) == 2)
    }

    @Test
    func a_pointer_past_the_edges_clamps_to_an_end_seam() {
        let seams: [CGFloat] = [0, 95, 190]
        #expect(TabMergePlacement.insertionIndex(x: -50, seams: seams) == 0)
        #expect(TabMergePlacement.insertionIndex(x: 900, seams: seams) == 2)
    }

    @Test
    func no_seams_resolves_to_the_first_index() {
        #expect(TabMergePlacement.insertionIndex(x: 10, seams: []) == 0)
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
