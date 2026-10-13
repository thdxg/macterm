@testable import Macterm
import Testing

/// The sidebar search of the Settings window (`SettingsPane.matching`).
struct SettingsViewTests {
    @Test
    func an_empty_query_keeps_every_pane_in_sidebar_order() {
        #expect(SettingsPane.matching("") == SettingsPane.allCases)
        #expect(SettingsPane.matching("   ") == SettingsPane.allCases)
    }

    @Test
    func a_title_match_comes_first() {
        #expect(SettingsPane.matching("keymaps").first == .keymaps)
        #expect(SettingsPane.matching("quick").first == .quickTerminal)
    }

    @Test
    func a_pane_is_found_by_a_setting_on_it() {
        #expect(SettingsPane.matching("opacity").first == .appearance)
        #expect(SettingsPane.matching("smooth cursor").first == .animations)
        #expect(SettingsPane.matching("passthrough").first == .keymaps)
        #expect(SettingsPane.matching("channel").first == .updates)
    }

    @Test
    func a_query_that_matches_nothing_finds_no_pane() {
        #expect(SettingsPane.matching("zzzqqq").isEmpty)
    }
}
