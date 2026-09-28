import CoreGraphics
@testable import Macterm
import Testing

@MainActor
struct DesktopWidgetTests {
    /// 164pt cells at a 180pt pitch from the default lattice's origin, (26,
    /// 842): 6 medium columns (0…5) and 4 rows (0…3) fit.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    private func frame(column: Int, row: Int, _ span: DesktopWidgetSpan) -> CGRect {
        DesktopWidgetGrid.frame(
            topLeft: DesktopWidgetGrid.topLeft(column: column, row: row, in: screen),
            span: span
        )
    }

    // MARK: - Metrics

    /// The system widgets' dimensions (chronod, macOS 27) are all spans of
    /// the one grid — the whole point of the grid is to sit among them.
    @Test
    func the_system_widget_sizes_are_grid_spans() {
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan.small) == CGSize(width: 164, height: 164))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan.medium) == CGSize(width: 344, height: 164))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan.large) == CGSize(width: 344, height: 344))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan.extraLarge) == CGSize(width: 704, height: 344))
        #expect(DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan(columns: 3, rows: 2)) == CGSize(width: 524, height: 344))
        #expect(DesktopWidgetMetrics.cornerRadius == 27.88)
    }

    @Test
    func sizes_parse_as_a_span_and_nothing_else() {
        #expect(DesktopWidgetSpan(parsing: "3x2") == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(DesktopWidgetSpan(parsing: "3X2") == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(DesktopWidgetSpan(parsing: "0x2") == nil)
        #expect(DesktopWidgetSpan(parsing: "large") == nil)
        #expect(DesktopWidgetSpan(columns: 2, rows: 1).description == "2x1")
        #expect(DesktopWidgetSpan.initial == DesktopWidgetSpan(columns: 3, rows: 3))
    }

    // MARK: - Widget

    /// The frame hangs down from `topLeft`, the corner a size change keeps.
    @Test
    func the_frame_hangs_down_from_the_top_left_corner() {
        let widget = DesktopWidget(span: DesktopWidgetSpan.medium, topLeft: CGPoint(x: 100, y: 800))
        #expect(widget.frame == CGRect(x: 100, y: 636, width: 344, height: 164))
        widget.span = DesktopWidgetSpan.large
        #expect(widget.frame == CGRect(x: 100, y: 456, width: 344, height: 344))
    }

    /// Widget panes belong to no project: they carry the widget routing id
    /// and group under their own slug in `zmx ls`.
    @Test
    func a_widget_pane_is_routed_outside_every_project() throws {
        let widget = DesktopWidget(span: DesktopWidgetSpan.small, topLeft: .zero)
        let pane = try #require(widget.pane)
        #expect(pane.projectID == DesktopWidget.projectID)
        #expect(pane.sessionName.hasPrefix("macterm-widget-"))
        #expect(pane.projectPath == NSHomeDirectory())
    }

    @Test
    func starting_over_gives_a_fresh_session_running_the_same_command() throws {
        let widget = DesktopWidget(span: DesktopWidgetSpan.small, topLeft: .zero, command: "htop")
        let before = try #require(widget.pane)
        widget.startOver()
        let after = try #require(widget.pane)
        #expect(after !== before)
        #expect(after.sessionName != before.sessionName)
        #expect(after.command == "htop")
        #expect(widget.tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Grid

    /// The default lattice starts where macOS puts a group of its own widgets
    /// against the top-left corner (measured: 26pt in, 33pt down).
    @Test
    func the_default_lattice_starts_at_the_system_widgets_corner_inset() {
        #expect(DesktopWidgetGrid.origin(in: screen) == CGPoint(x: 26, y: 842))
    }

    /// Exactly the middle, off the lattice — its nearest cell is up to half
    /// a pitch away. 524pt square on a 1440×875 screen: (458, 437.5 + 262).
    @Test
    func a_new_widget_goes_in_the_exact_middle_of_the_screen() {
        let topLeft = DesktopWidgetGrid.centered(.initial, in: screen, avoiding: [])
        #expect(topLeft == CGPoint(x: 458, y: 700))
    }

    @Test
    func a_new_widget_takes_the_nearest_free_cell_when_the_middle_is_taken() {
        let middle = DesktopWidgetGrid.centered(DesktopWidgetSpan.medium, in: screen, avoiding: [])
        #expect(middle == CGPoint(x: 548, y: 520))
        let occupied = [DesktopWidgetGrid.frame(topLeft: middle, span: .medium)]
        let topLeft = DesktopWidgetGrid.centered(DesktopWidgetSpan.medium, in: screen, avoiding: occupied)
        #expect(topLeft == CGPoint(x: 386, y: 842))
    }

    /// A drag lands anywhere; the widget settles into the nearest cell.
    @Test
    func a_dragged_widget_snaps_to_the_nearest_cell() {
        let dropped = CGRect(x: 400, y: 530, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [])
        #expect(snapped.topLeft == CGPoint(x: 386, y: 662))
        #expect(snapped.span == DesktopWidgetSpan.medium)
    }

    /// A resize lands at any size; the widget settles into the nearest span.
    @Test
    func a_resized_widget_snaps_to_the_nearest_span() {
        let resized = CGRect(x: 16, y: 509, width: 520, height: 350)
        let snapped = DesktopWidgetGrid.snap(resized, in: screen, avoiding: [])
        #expect(snapped.span == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(snapped.topLeft == CGPoint(x: 26, y: 842))
    }

    @Test
    func a_widget_dragged_past_the_edge_stays_on_the_screen() {
        let dropped = CGRect(x: 2000, y: -100, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [])
        // The last columns and row that hold a medium widget.
        #expect(snapped.topLeft == CGPoint(x: 926, y: 302))
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
        #expect(snapped.topLeft == CGPoint(x: 386, y: 842))
    }

    // MARK: - Groups

    /// macOS lays its widgets out in groups, each on its own lattice from
    /// wherever the group was dropped. A widget let go near one joins that
    /// lattice, so it lines up with the system's widgets beside it.
    @Test
    func a_widget_let_go_near_another_joins_its_lattice() {
        // A native medium widget at an origin off the default lattice.
        let native = CGRect(x: 507, y: 401, width: 344, height: 164)
        let dropped = CGRect(x: 880, y: 390, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [native])
        #expect(snapped.topLeft == CGPoint(x: native.minX + 360, y: native.maxY))
    }

    @Test
    func a_widget_let_go_in_open_space_uses_the_default_lattice() {
        let native = CGRect(x: 1007, y: 11, width: 164, height: 164)
        let dropped = CGRect(x: 30, y: 670, width: 344, height: 164)
        let snapped = DesktopWidgetGrid.snap(dropped, in: screen, avoiding: [native])
        #expect(snapped.topLeft == DesktopWidgetGrid.origin(in: screen))
    }

    /// Joining is for neighbours: a widget more than a cell's pitch away
    /// doesn't pull a widget onto its lattice.
    @Test
    func only_a_neighbour_within_a_pitch_shares_its_lattice() {
        let native = CGRect(x: 507, y: 401, width: 344, height: 164)
        let near = CGRect(x: 507 + 344 + 100, y: 401, width: 10, height: 10)
        let far = CGRect(x: 507 + 344 + 200, y: 401, width: 10, height: 10)
        let origin = DesktopWidgetGrid.origin(in: screen)
        #expect(DesktopWidgetGrid.lattice(for: near, in: screen, neighbours: [native]) == CGPoint(x: 507, y: 565))
        #expect(DesktopWidgetGrid.lattice(for: far, in: screen, neighbours: [native]) == origin)
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

/// The system's widget families, as spans — what these tests size widgets by.
private extension DesktopWidgetSpan {
    static let small = DesktopWidgetSpan(columns: 1, rows: 1)
    static let medium = DesktopWidgetSpan(columns: 2, rows: 1)
    static let large = DesktopWidgetSpan(columns: 2, rows: 2)
    static let extraLarge = DesktopWidgetSpan(columns: 4, rows: 2)
}
