@testable import Macterm
import Testing

@MainActor
struct TerminalSearchStateTests {
    @Test
    func displayText_is_one_indexed() {
        let state = TerminalSearchState()
        state.total = 5
        state.selected = 0
        #expect(state.displayText == "1 of 5")

        state.selected = 4
        #expect(state.displayText == "5 of 5")
    }

    @Test
    func displayText_falls_back_to_match_count_without_selection() {
        let state = TerminalSearchState()
        state.total = 5
        state.selected = nil
        #expect(state.displayText == "5 matches")
    }

    @Test
    func displayText_is_empty_without_total() {
        let state = TerminalSearchState()
        #expect(state.displayText.isEmpty)
    }
}
