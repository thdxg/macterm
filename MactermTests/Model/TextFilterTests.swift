@testable import Macterm
import Testing

struct TextFilterTests {
    @Test
    func every_word_must_appear_in_some_field() {
        #expect(TextFilter.matches("split right", in: ["Split Right", "Panes"]))
        #expect(TextFilter.matches("panes right", in: ["Split Right", "Panes"]), "words may come from different fields")
        #expect(!TextFilter.matches("split left", in: ["Split Right", "Panes"]))
    }

    @Test
    func case_and_diacritics_are_ignored_and_an_empty_query_matches() {
        #expect(TextFilter.matches("CAFE", in: ["café"]))
        #expect(TextFilter.matches("", in: ["anything"]))
        #expect(TextFilter.matches("   ", in: []))
    }
}

@MainActor
struct KeymapSearchTests {
    @Test
    func an_action_is_found_by_title_section_or_chord_either_way_written() {
        let fields = HotkeyAction.splitRight.searchFields(shortcut: "cmd+d")
        #expect(TextFilter.matches("split", in: fields))
        #expect(TextFilter.matches("panes", in: fields))
        #expect(TextFilter.matches("cmd+d", in: fields))
        #expect(TextFilter.matches("⌘D", in: fields))
        #expect(!TextFilter.matches("tabs", in: fields))
    }

    @Test
    func an_unbound_action_is_found_by_none_but_not_by_its_raw_spelling() {
        let fields = HotkeyAction.pinTab.searchFields(shortcut: "none")
        #expect(TextFilter.matches("none", in: fields), "shown as None")
        #expect(!TextFilter.matches("disabled", in: HotkeyAction.pinTab.searchFields(shortcut: "disabled")))
    }
}
