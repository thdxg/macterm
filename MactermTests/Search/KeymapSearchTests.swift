@testable import Macterm
import Testing

@MainActor
struct KeymapSearchTests {
    @Test
    func keymaps_list_every_bindable_action_in_the_palettes_order_palettes_first() {
        let ordered = HotkeyAction.inCommandOrder
        #expect(Set(ordered) == Set(HotkeyAction.allCases), "every bindable action is listed once")
        #expect(ordered.count == HotkeyAction.allCases.count)
        #expect(ordered.first?.appCommand.category == .palettes)
        #expect(ordered.prefix(4).map(\.appCommand) == [.toggleCommandPalette, .passwordManager, .worktrees, .files])
        // Categories are contiguous runs, as the palette's sections are.
        let categories = ordered.map(\.appCommand.category)
        var seen: [AppCommand.Category] = []
        for category in categories where seen.last != category {
            #expect(!seen.contains(category), "\(category) appears in two runs")
            seen.append(category)
        }
    }

    @Test
    func an_action_is_found_by_title_section_or_chord_either_way_written() {
        let fields = HotkeyAction.splitRight.searchFields(shortcut: "cmd+d")
        #expect(Search.matches("split", in: fields))
        #expect(Search.matches("panes", in: fields))
        #expect(Search.matches("cmd+d", in: fields))
        #expect(Search.matches("⌘D", in: fields))
        #expect(!Search.matches("tabs", in: fields))
    }

    @Test
    func an_unbound_action_is_found_by_none_but_not_by_its_raw_spelling() {
        let fields = HotkeyAction.pinTab.searchFields(shortcut: "none")
        #expect(Search.matches("none", in: fields), "shown as None")
        #expect(!Search.matches("disabled", in: HotkeyAction.pinTab.searchFields(shortcut: "disabled")))
    }
}
