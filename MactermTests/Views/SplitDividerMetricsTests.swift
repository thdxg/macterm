import CoreGraphics
@testable import Macterm
import Testing

/// Pure geometry behind the split divider's drag band (#260). UI behavior isn't
/// unit-tested per the project's conventions, but where the band sits and where
/// a drag lands are plain arithmetic worth pinning — the clamping in particular,
/// which is what keeps the band inside the container and the ratio inside the
/// bounds `pane.resize-split` promises.
struct SplitDividerMetricsTests {
    private let thickness = SplitDividerMetrics.bandThickness

    // MARK: - bandOffset

    @Test
    func band_is_centered_on_the_divider() {
        // Divider at 500 in a 1000pt container: a 10pt band starts 5pt before it.
        #expect(SplitDividerMetrics.bandOffset(total: 1000, ratio: 0.5) == 500 - thickness / 2)
    }

    @Test
    func band_follows_an_off_center_divider() {
        #expect(SplitDividerMetrics.bandOffset(total: 1000, ratio: 0.15) == 150 - thickness / 2)
    }

    @Test
    func band_never_starts_before_the_leading_edge() {
        // Divider at 3pt: centering would put the band at -2.
        #expect(SplitDividerMetrics.bandOffset(total: 20, ratio: 0.15) == 0)
    }

    @Test
    func band_never_runs_past_the_trailing_edge() {
        // Divider at 17 of 20pt: centering would put the band at 12, hanging
        // 2pt off the end. It stops where it still fits.
        #expect(SplitDividerMetrics.bandOffset(total: 20, ratio: 0.85) == 20 - thickness)
    }

    @Test
    func band_collapses_to_the_leading_edge_when_the_container_is_thinner_than_the_band() {
        // Degenerate geometry (a container narrower than the band itself):
        // clamp to 0 rather than to a negative upper bound.
        #expect(SplitDividerMetrics.bandOffset(total: 6, ratio: 0.5) == 0)
        #expect(SplitDividerMetrics.bandOffset(total: 0, ratio: 0.5) == 0)
    }

    // MARK: - draggedRatio

    @Test
    func drag_moves_the_ratio_by_the_distance_travelled() {
        // A quarter of the container to the right of where the drag began.
        #expect(SplitDividerMetrics.draggedRatio(start: 0.5, delta: 250, total: 1000) == 0.75)
    }

    @Test
    func drag_back_moves_the_ratio_the_other_way() {
        #expect(SplitDividerMetrics.draggedRatio(start: 0.5, delta: -125, total: 1000) == 0.375)
    }

    @Test
    func drag_is_measured_from_the_start_ratio_not_the_current_one() {
        // Same travel from a different origin lands somewhere else — this is
        // what keeps a drag from accumulating against a divider that moves
        // with the pointer.
        #expect(SplitDividerMetrics.draggedRatio(start: 0.25, delta: 250, total: 1000) == 0.5)
    }

    @Test
    func drag_clamps_to_the_upper_bound() {
        #expect(SplitDividerMetrics.draggedRatio(start: 0.8, delta: 400, total: 1000) == SplitDividerMetrics.maxRatio)
    }

    @Test
    func drag_clamps_to_the_lower_bound() {
        #expect(SplitDividerMetrics.draggedRatio(start: 0.2, delta: -400, total: 1000) == SplitDividerMetrics.minRatio)
    }

    @Test
    func drag_in_a_zero_sized_container_holds_the_start_ratio() {
        // No axis to measure against: hold still instead of dividing by zero.
        #expect(SplitDividerMetrics.draggedRatio(start: 0.4, delta: 250, total: 0) == 0.4)
    }
}
