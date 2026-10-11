@testable import Macterm
import Testing

struct SurfaceVisibilityTests {
    private func visible(
        preview: Bool = false,
        hidden: Bool = false,
        onScreen: Bool,
        reportsVisible: Bool,
        reported: Bool
    ) -> Bool {
        SurfaceVisibility.isVisible(
            rendersForPreview: preview,
            hiddenInLayout: hidden,
            windowIsVisible: onScreen,
            windowReportsVisible: reportsVisible,
            windowHasReportedOcclusion: reported
        )
    }

    /// A window that just opened is on screen before AppKit reports its
    /// occlusion. Its panes must draw, or they show a buffer nothing drew.
    @Test
    func an_on_screen_window_with_no_report_yet_is_visible() {
        #expect(visible(onScreen: true, reportsVisible: false, reported: false))
    }

    /// After the first report, the report is the only source: a covered
    /// window parks its renderers although it is still on screen.
    @Test
    func a_reported_window_follows_its_report() {
        #expect(!visible(onScreen: true, reportsVisible: false, reported: true))
        #expect(visible(onScreen: true, reportsVisible: true, reported: true))
    }

    /// The surface incubator is never ordered on screen and reports nothing.
    @Test
    func a_window_that_is_not_on_screen_is_occluded() {
        #expect(!visible(onScreen: false, reportsVisible: false, reported: false))
    }

    @Test
    func a_tile_hidden_by_zoom_is_occluded_in_any_window() {
        #expect(!visible(hidden: true, onScreen: true, reportsVisible: true, reported: true))
        #expect(!visible(hidden: true, onScreen: true, reportsVisible: false, reported: false))
    }

    @Test
    func a_preview_draws_wherever_the_pane_is() {
        #expect(visible(preview: true, hidden: true, onScreen: false, reportsVisible: false, reported: true))
    }
}
