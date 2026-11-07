@testable import Macterm
import Testing

struct TerminalFontFamilyTests {
    /// A stand-in for the installed fonts: names map to a canonical family.
    private static let installed: [String: String] = [
        "menlo": "Menlo",
        "menlo-bold": "Menlo",
        "sf mono": "SF Mono",
    ]

    private static func family(_ name: String) -> String? {
        installed[name.lowercased()]
    }

    @Test
    func each_line_appends_a_family_in_order() {
        let text = "font-family = Menlo\nfont-size = 14\nfont-family = \"SF Mono\"\n"
        #expect(TerminalFontFamily.families(inConfigText: text) == ["Menlo", "SF Mono"])
    }

    @Test
    func an_empty_value_clears_the_list() {
        let text = "font-family = Menlo\nfont-family =\nfont-family = SF Mono\n"
        #expect(TerminalFontFamily.families(inConfigText: text) == ["SF Mono"])
        #expect(TerminalFontFamily.families(inConfigText: "font-family = Menlo\nfont-family = \"\"\n").isEmpty)
    }

    @Test
    func other_font_keys_are_not_the_family() {
        let text = "font-family-bold = Menlo\n# font-family = Menlo\nfont-size = 12\n"
        #expect(TerminalFontFamily.families(inConfigText: text).isEmpty)
    }

    @Test
    func the_first_installed_family_wins_by_its_canonical_name() {
        let text = "font-family = menlo\nfont-family = SF Mono\n"
        #expect(TerminalFontFamily.resolve(userConfigText: text, familyOfFont: Self.family) == "Menlo")
    }

    @Test
    func a_missing_family_falls_through_to_the_next_one() {
        let text = "font-family = Not Installed\nfont-family = SF Mono\n"
        #expect(TerminalFontFamily.resolve(userConfigText: text, familyOfFont: Self.family) == "SF Mono")
    }

    @Test
    func a_postscript_name_resolves_to_its_family() {
        #expect(TerminalFontFamily.resolve(userConfigText: "font-family = Menlo-Bold", familyOfFont: Self.family) == "Menlo")
    }

    @Test
    func no_config_no_key_or_nothing_installed_is_the_system_font() {
        #expect(TerminalFontFamily.resolve(userConfigText: nil, familyOfFont: Self.family) == nil)
        #expect(TerminalFontFamily.resolve(userConfigText: "font-size = 14", familyOfFont: Self.family) == nil)
        #expect(TerminalFontFamily.resolve(userConfigText: "font-family = Nope", familyOfFont: Self.family) == nil)
    }

    @Test
    func the_live_lookup_knows_an_installed_font_and_refuses_an_unknown_name() {
        #expect(TerminalFontFamily.installedFamily(named: "menlo") == "Menlo")
        #expect(TerminalFontFamily.installedFamily(named: "Menlo-Bold") == "Menlo")
        #expect(TerminalFontFamily.installedFamily(named: "No Such Font 8d1f") == nil)
    }
}
