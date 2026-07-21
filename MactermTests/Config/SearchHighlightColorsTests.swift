@testable import Macterm
import Testing

struct SearchHighlightColorsTests {
    @Test
    func defaults_match_ghosttys_documented_values() {
        #expect(SearchHighlightColors.matchBackground(inConfigText: nil)
            == SearchHighlightColors.RGB(r: 0xFF, g: 0xE0, b: 0x82))
        #expect(SearchHighlightColors.selectedBackground(inConfigText: nil)
            == SearchHighlightColors.RGB(r: 0xF2, g: 0xA5, b: 0x7E))
    }

    @Test
    func hex_overrides_are_honored_with_and_without_hash() {
        let text = """
        search-background = #102030
        search-selected-background = A0B0C0
        """
        #expect(SearchHighlightColors.matchBackground(inConfigText: text)
            == SearchHighlightColors.RGB(r: 0x10, g: 0x20, b: 0x30))
        #expect(SearchHighlightColors.selectedBackground(inConfigText: text)
            == SearchHighlightColors.RGB(r: 0xA0, g: 0xB0, b: 0xC0))
    }

    @Test
    func last_occurrence_wins() {
        let text = """
        search-background = #111111
        search-background = #222222
        """
        #expect(SearchHighlightColors.matchBackground(inConfigText: text)
            == SearchHighlightColors.RGB(r: 0x22, g: 0x22, b: 0x22))
    }

    @Test
    func comments_and_other_keys_are_ignored() {
        let text = """
        # search-background = #111111
        search-selected-background = #333333
        background = #444444
        """
        #expect(SearchHighlightColors.matchBackground(inConfigText: text)
            == SearchHighlightColors.defaultMatch)
    }

    @Test
    func quoted_values_are_unwrapped() {
        let text = "search-background = \"#555555\""
        #expect(SearchHighlightColors.matchBackground(inConfigText: text)
            == SearchHighlightColors.RGB(r: 0x55, g: 0x55, b: 0x55))
    }

    @Test
    func unrepresentable_values_fall_back_to_the_default() {
        // Named X11 colors and cell-* are valid ghostty values a tick can't
        // reproduce; an empty value resets the key. All take the default —
        // even when an earlier occurrence was a parseable hex, since the last
        // occurrence is what ghostty renders.
        for value in ["cell-foreground", "goldenrod", ""] {
            let text = "search-background = #111111\nsearch-background = \(value)"
            #expect(SearchHighlightColors.matchBackground(inConfigText: text)
                == SearchHighlightColors.defaultMatch)
        }
    }
}
