@testable import Macterm
import Testing

struct ThemeResolverTests {
    // MARK: - resolve(themeValue:scheme:)

    @Test
    func split_picks_matching_side() {
        let value = "light:branch,dark:Builtin Tango Dark"
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    @Test
    func split_order_does_not_matter() {
        let value = "dark:Builtin Tango Dark,light:branch"
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    @Test
    func plain_theme_is_not_resolved() {
        #expect(ThemeResolver.resolve(themeValue: "Rose Pine", scheme: .dark) == nil)
        #expect(ThemeResolver.resolve(themeValue: "Builtin Tango Light", scheme: .light) == nil)
    }

    @Test
    func empty_is_not_resolved() {
        #expect(ThemeResolver.resolve(themeValue: "", scheme: .dark) == nil)
        #expect(ThemeResolver.resolve(themeValue: "   ", scheme: .light) == nil)
    }

    @Test
    func partial_split_falls_back_to_present_side() {
        #expect(ThemeResolver.resolve(themeValue: "dark:Tokyo Night", scheme: .light) == "Tokyo Night")
        #expect(ThemeResolver.resolve(themeValue: "light:Catppuccin", scheme: .dark) == "Catppuccin")
    }

    @Test
    func whitespace_around_pairs_is_trimmed() {
        let value = " light : branch , dark : Builtin Tango Dark "
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .light) == "branch")
        #expect(ThemeResolver.resolve(themeValue: value, scheme: .dark) == "Builtin Tango Dark")
    }

    // MARK: - themeValue(inConfigText:)

    @Test
    func reads_theme_line() {
        let text = "font-size = 16\ntheme = light:branch,dark:Tango\nwindow-padding-x = 16\n"
        #expect(ThemeResolver.themeValue(inConfigText: text) == "light:branch,dark:Tango")
    }

    @Test
    func last_theme_line_wins() {
        let text = "theme = Rose Pine\ntheme = light:branch,dark:Tango\n"
        #expect(ThemeResolver.themeValue(inConfigText: text) == "light:branch,dark:Tango")
    }

    @Test
    func ignores_comments_and_blanks() {
        let text = "# theme = ignored\n\n  theme = Tokyo Night  \n"
        #expect(ThemeResolver.themeValue(inConfigText: text) == "Tokyo Night")
    }

    @Test
    func strips_surrounding_quotes() {
        let text = "theme = \"Rose Pine\"\n"
        #expect(ThemeResolver.themeValue(inConfigText: text) == "Rose Pine")
    }

    @Test
    func no_theme_line_returns_nil() {
        #expect(ThemeResolver.themeValue(inConfigText: "font-size = 16\n") == nil)
    }

    @Test
    func does_not_match_keys_that_contain_theme() {
        let text = "window-theme = dark\n"
        #expect(ThemeResolver.themeValue(inConfigText: text) == nil)
    }

    // MARK: - colors(inThemeFile:)

    @Test
    func parses_background_foreground_and_palette() {
        let text = """
        # Rose Pine
        background = #191724
        foreground = #e0def4
        palette = 0=#26233a
        palette = 1=#eb6f92
        palette = 15=#e0def4
        """
        let colors = ThemeResolver.colors(inThemeFile: text)
        #expect(colors.background == "#191724")
        #expect(colors.foreground == "#e0def4")
        #expect(colors.palette[0] == "#26233a")
        #expect(colors.palette[1] == "#eb6f92")
        #expect(colors.palette[15] == "#e0def4")
        #expect(colors.palette[2] == nil)
    }

    @Test
    func missing_entries_are_nil_or_empty() {
        let colors = ThemeResolver.colors(inThemeFile: "font-size = 14\n")
        #expect(colors.background == nil)
        #expect(colors.foreground == nil)
        #expect(colors.palette.isEmpty)
    }

    @Test
    func ignores_comments_in_theme_file() {
        let text = "# background = #ffffff\nbackground = #000000\n"
        #expect(ThemeResolver.colors(inThemeFile: text).background == "#000000")
    }
}
