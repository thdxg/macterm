@testable import Macterm
import Testing

struct WindowThemeTests {
    /// The raw values are ghostty's own `WindowTheme` tag names, so a rename
    /// here is a wire break.
    @Test
    func theWireVocabularyIsGhosttysOwn() {
        #expect(WindowTheme.allCases.map(\.rawValue) == ["auto", "system", "light", "dark", "ghostty"])
        #expect(WindowTheme.key.name == "window-theme")
    }

    @Test
    func anUnsetOrUnknownKeyIsAuto() {
        #expect(WindowTheme.resolve(configValue: nil) == .auto)
        #expect(WindowTheme.resolve(configValue: "") == .auto)
        #expect(WindowTheme.resolve(configValue: "sepia") == .auto)
        #expect(WindowTheme.resolve(configValue: " Dark ") == .dark)
    }

    /// `auto` keeps the rule from before the key counted: the chrome follows
    /// the terminal background.
    @Test
    func autoFollowsTheBackground() {
        for system in [ThemeResolver.Scheme.light, .dark] {
            #expect(WindowTheme.scheme(configured: .auto, override: nil, system: system) == nil)
        }
    }

    @Test
    func lightAndDarkIgnoreTheSystem() {
        for system in [ThemeResolver.Scheme.light, .dark] {
            #expect(WindowTheme.scheme(configured: .light, override: nil, system: system) == .light)
            #expect(WindowTheme.scheme(configured: .dark, override: nil, system: system) == .dark)
        }
    }

    /// `ghostty` is a GTK value. Ghostty.app sets no appearance for it, so it
    /// follows macOS like `system`.
    @Test
    func systemAndGhosttyFollowTheSystem() {
        for configured in [WindowTheme.system, .ghostty] {
            #expect(WindowTheme.scheme(configured: configured, override: nil, system: .light) == .light)
            #expect(WindowTheme.scheme(configured: configured, override: nil, system: .dark) == .dark)
        }
    }

    @Test
    func theOverrideWinsOverEveryKey() {
        for configured in WindowTheme.allCases {
            #expect(WindowTheme.scheme(configured: configured, override: .light, system: .dark) == .light)
            #expect(WindowTheme.scheme(configured: configured, override: .dark, system: .light) == .dark)
            #expect(WindowTheme.scheme(configured: configured, override: .system, system: .dark) == .dark)
            #expect(WindowTheme.scheme(configured: configured, override: .system, system: .light) == .light)
        }
    }
}
