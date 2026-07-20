@testable import Macterm
import Testing

struct SearchTicksTests {
    @Test
    func finds_matches_on_their_lines() {
        let text = "alpha\nbeta\nalpha again"
        #expect(SearchTicks.matchRows(text: text, needle: "alpha", cols: 80) == [0, 2])
    }

    @Test
    func matching_is_ascii_case_insensitive() {
        let text = "Error\nerror\nERROR"
        #expect(SearchTicks.matchRows(text: text, needle: "eRRor", cols: 80) == [0, 1, 2])
    }

    @Test
    func multiple_matches_on_one_row_repeat_the_row() {
        // One entry per match keeps indices 1:1 with ghostty's match list.
        let text = "foo foo foo"
        #expect(SearchTicks.matchRows(text: text, needle: "foo", cols: 80) == [0, 0, 0])
    }

    @Test
    func matches_do_not_overlap() {
        // Mirrors ghostty's sliding-window scan: "aaaa" holds two "aa", not three.
        #expect(SearchTicks.matchRows(text: "aaaa", needle: "aa", cols: 80) == [0, 0])
    }

    @Test
    func long_lines_wrap_at_cols() {
        // 10-wide grid: 25 chars of padding occupy rows 0–2, the needle starts
        // at code point 25 → row 2; next logical line starts at row 3.
        let text = String(repeating: "x", count: 25) + "hit\nhit"
        let rows = SearchTicks.matchRows(text: text, needle: "hit", cols: 10)
        #expect(rows == [2, 3])
    }

    @Test
    func wrapped_match_row_is_its_start_row() {
        // Needle starting at code point 8 of a 10-wide row sits on row 0 even
        // though it spills onto row 1.
        let text = String(repeating: "x", count: 8) + "needle"
        #expect(SearchTicks.matchRows(text: text, needle: "needle", cols: 10) == [0])
    }

    @Test
    func empty_lines_still_occupy_a_row() {
        let text = "top\n\n\nbottom"
        #expect(SearchTicks.matchRows(text: text, needle: "bottom", cols: 80) == [3])
    }

    @Test
    func line_exactly_cols_wide_occupies_one_row() {
        let text = String(repeating: "x", count: 10) + "\nhit"
        #expect(SearchTicks.matchRows(text: text, needle: "hit", cols: 10) == [1])
    }

    @Test
    func multibyte_text_counts_code_points_not_bytes() {
        // "é" is 2 UTF-8 bytes but 1 code point/cell; 10 of them fill exactly
        // one 10-wide row, so the needle on the next line sits on row 1.
        let text = String(repeating: "é", count: 10) + "\nhit"
        #expect(SearchTicks.matchRows(text: text, needle: "hit", cols: 10) == [1])
    }

    @Test
    func degenerate_inputs_return_no_rows() {
        #expect(SearchTicks.matchRows(text: "abc", needle: "", cols: 80).isEmpty)
        #expect(SearchTicks.matchRows(text: "abc", needle: "abc", cols: 0).isEmpty)
        #expect(SearchTicks.matchRows(text: "", needle: "abc", cols: 80).isEmpty)
        #expect(SearchTicks.matchRows(text: "a\nb", needle: "a\nb", cols: 80).isEmpty)
    }

    @Test
    func selected_index_counts_from_the_end() {
        // ghostty's SEARCH_SELECTED index 0 is the newest (bottom-most) match.
        let rows = [1, 5, 9]
        #expect(SearchTicks.selectedRow(rows: rows, selectedFromEnd: 0) == 9)
        #expect(SearchTicks.selectedRow(rows: rows, selectedFromEnd: 2) == 1)
    }

    @Test
    func selected_index_out_of_range_is_nil() {
        let rows = [1, 5]
        #expect(SearchTicks.selectedRow(rows: rows, selectedFromEnd: nil) == nil)
        #expect(SearchTicks.selectedRow(rows: rows, selectedFromEnd: 2) == nil)
        #expect(SearchTicks.selectedRow(rows: rows, selectedFromEnd: -1) == nil)
        #expect(SearchTicks.selectedRow(rows: [], selectedFromEnd: 0) == nil)
    }
}
