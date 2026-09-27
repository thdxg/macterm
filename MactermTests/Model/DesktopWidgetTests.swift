import CoreGraphics
@testable import Macterm
import Testing

@MainActor
struct DesktopWidgetTests {
    /// 7 columns × 4 rows of 164pt cells at a 180pt pitch, from (16, 859).
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    private func frame(column: Int, row: Int, _ size: DesktopWidgetSize) -> CGRect {
        DesktopWidgetGrid.frame(
            topLeft: DesktopWidgetGrid.topLeft(column: column, row: row, in: screen),
            span: size.span
        )
    }

    // MARK: - Metrics

    /// The system widgets' dimensions (chronod, macOS 27) are all spans of
    /// the one grid — the whole point of the sizes is to sit among them.
    @Test
    func the_families_are_grid_spans_at_the_system_widget_sizes() {
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSize.small.span) == CGSize(width: 164, height: 164))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSize.medium.span) == CGSize(width: 344, height: 164))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSize.large.span) == CGSize(width: 344, height: 344))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSize.extraLarge.span) == CGSize(width: 704, height: 344))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan(columns: 3, rows: 2)) == CGSize(width: 524, height: 344))
        #expect(DesktopWidgetMetrics.cornerRadius == 27.88)
    }

    @Test
    func sizes_parse_as_a_family_name_or_a_span() {
        #expect(DesktopWidgetSize.parseSpan("large") == DesktopWidgetSpan(columns: 2, rows: 2))
        #expect(DesktopWidgetSize.parseSpan("Extra-Large") == DesktopWidgetSpan(columns: 4, rows: 2))
        #expect(DesktopWidgetSize.parseSpan("3x2") == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(DesktopWidgetSize.parseSpan("0x2") == nil)
        #expect(DesktopWidgetSize.parseSpan("huge") == nil)
        #expect(DesktopWidgetSize.name(of: DesktopWidgetSpan(columns: 2, rows: 1)) == "medium")
        #expect(DesktopWidgetSize.name(of: DesktopWidgetSpan(columns: 3, rows: 2)) == "3x2")
    }

    // MARK: - Widget

    /// The frame hangs down from `topLeft`, the corner a size change keeps.
    @Test
    func the_frame_hangs_down_from_the_top_left_corner() {
        let widget = DesktopWidget(span: DesktopWidgetSize.medium.span, topLeft: CGPoint(x: 100, y: 800))
        #expect(widget.frame == CGRect(x: 100, y: 636, width: 344, height: 164))
        widget.span = DesktopWidgetSize.large.span
        #expect(widget.frame == CGRect(x: 100, y: 456, width: 344, height: 344))
    }

    /// Widget panes belong to no project: they carry the widget routing id
    /// and group under their own slug in `zmx ls`.
    @Test
    func a_widget_pane_is_routed_outside_every_project() throws {
        let widget = DesktopWidget(span: DesktopWidgetSize.small.span, topLeft: .zero)
        let pane = try #require(widget.pane)
        #expect(pane.projectID == DesktopWidget.projectID)
        #expect(pane.sessionName.hasPrefix("macterm-widget-"))
        #expect(pane.projectPath == NSHomeDirectory())
    }

    @Test
    func starting_over_gives_a_fresh_session_running_the_same_command() throws {
        let widget = DesktopWidget(span: DesktopWidgetSize.small.span, topLeft: .zero, command: "htop")
        let before = try #require(widget.pane)
        widget.startOver()
        let after = try #require(widget.pane)
        #expect(after !== before)
        #expect(after.sessionName != before.sessionName)
        #expect(after.command == "htop")
        #expect(widget.tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Grid

    @Test
    func the_grid_fits_whole_cells_inside_the_screen_margins() {
        #expect(DesktopWidgetGrid.capacity(of: screen) == DesktopWidgetSpan(columns: 7, rows: 4))
        #expect(DesktopWidgetGrid.origin(in: screen) == CGPoint(x: 16, y: 859))
        // A screen smaller than a cell still has one.
        #expect(DesktopWidgetGrid.capacity(of: CGRect(x: 0, y: 0, width: 100, height: 100)) == DesktopWidgetSpan(columns: 1, rows: 1))
    }

    @Test
    func a_new_widget_goes_in_the_middle_of_the_screen() {
        let topLeft = DesktopWidgetGrid.centered(DesktopWidgetSize.medium.span, in: screen, avoiding: [])
        #expect(topLeft == CGPoint(x: 376, y: 679))
    }

    @Test
    func a_new_widget_takes_the_nearest_free_cell_when_the_middle_is_taken() {
        let occupied = [frame(column: 2, row: 1, .medium)]
        let topLeft = DesktopWidgetGrid.centered(DesktopWidgetSize.medium.span, in: screen, avoiding: occupied)
        #expect(topLeft == CGPoint(x: 376, y: 859))
    }

    /// A drag lands anywhere; the widget settles into the nearest cell.
    @Test
    func a_dragged_widget_snaps_to_the_nearest_cell() {
        let dropped = CGRect(x: 400, y: 530, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [])
        #expect(snapped.topLeft == CGPoint(x: 376, y: 679))
        #expect(snapped.span == DesktopWidgetSize.medium.span)
    }

    /// A resize lands at any size; the widget settles into the nearest span.
    @Test
    func a_resized_widget_snaps_to_the_nearest_span() {
        let resized = CGRect(x: 16, y: 509, width: 520, height: 350)
        let snapped = DesktopWidgetGrid.snap(resized, in: screen, avoiding: [])
        #expect(snapped.span == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(snapped.topLeft == CGPoint(x: 16, y: 859))
    }

    @Test
    func a_widget_dragged_past_the_edge_stays_on_the_screen() {
        let dropped = CGRect(x: 2000, y: -100, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [])
        // The last columns and row that hold a medium widget.
        #expect(snapped.topLeft == CGPoint(x: 916, y: 319))
    }

    @Test
    func a_widget_never_grows_past_the_screen() {
        let huge = CGRect(x: 16, y: -2000, width: 3000, height: 2859)
        #expect(DesktopWidgetGrid.snap(huge, in: screen, avoiding: []).span == DesktopWidgetSpan(columns: 7, rows: 4))
    }

    /// Widgets don't stack: one dropped onto another moves to the nearest
    /// free cell.
    @Test
    func a_widget_dropped_on_another_moves_to_the_nearest_free_cell() {
        let occupied = [frame(column: 2, row: 1, .medium)]
        let snapped = DesktopWidgetGrid.snap(frame(column: 2, row: 1, .medium), in: screen, avoiding: occupied)
        #expect(snapped.topLeft == CGPoint(x: 376, y: 859))
    }

    /// Cells are laid out with the gap inside the pitch, so neighbours touch
    /// only across a gap and never count as overlapping.
    @Test
    func neighbouring_cells_are_both_free() {
        let occupied = [frame(column: 0, row: 0, .small)]
        let snapped = DesktopWidgetGrid.snap(frame(column: 1, row: 0, .small), in: screen, avoiding: occupied)
        #expect(snapped.topLeft == DesktopWidgetGrid.topLeft(column: 1, row: 0, in: screen))
    }

    @Test
    func a_frame_needs_enough_of_itself_on_some_screen_to_be_reachable() {
        let screens = [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(DesktopWidgetGrid.isReachable(CGRect(x: 100, y: 100, width: 344, height: 164), on: screens))
        #expect(DesktopWidgetGrid.isReachable(CGRect(x: 2000, y: 500, width: 344, height: 164), on: screens))
        #expect(!DesktopWidgetGrid.isReachable(CGRect(x: -314, y: 100, width: 344, height: 164), on: screens))
        #expect(!DesktopWidgetGrid.isReachable(CGRect(x: 5000, y: 100, width: 344, height: 164), on: screens))
    }

    @Test
    func a_frame_belongs_to_the_screen_holding_its_center() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let straddling = CGRect(x: 1300, y: 100, width: 344, height: 164)
        #expect(DesktopWidgetGrid.screen(for: straddling, among: [screen, second]) == second)
    }
}
