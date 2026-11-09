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

    /// `auto` follows the terminal background, also for the surfaces, as in
    /// Ghostty.app. It is the rule from before the key counted.
    @Test
    func autoFollowsTheBackground() {
        for system in [ThemeResolver.Scheme.light, .dark] {
            #expect(WindowTheme.scheme(configured: .auto, override: nil, system: system, backgroundIsLight: true) == .light)
            #expect(WindowTheme.scheme(configured: .auto, override: nil, system: system, backgroundIsLight: false) == .dark)
        }
    }

    @Test
    func lightAndDarkIgnoreTheSystemAndTheBackground() {
        for system in [ThemeResolver.Scheme.light, .dark] {
            for light in [true, false] {
                #expect(WindowTheme.scheme(configured: .light, override: nil, system: system, backgroundIsLight: light) == .light)
                #expect(WindowTheme.scheme(configured: .dark, override: nil, system: system, backgroundIsLight: light) == .dark)
            }
        }
    }

    /// `ghostty` is a GTK value. Ghostty.app sets no appearance for it, so it
    /// follows macOS like `system`.
    @Test
    func systemAndGhosttyFollowTheSystem() {
        for configured in [WindowTheme.system, .ghostty] {
            #expect(WindowTheme.scheme(configured: configured, override: nil, system: .light, backgroundIsLight: false) == .light)
            #expect(WindowTheme.scheme(configured: configured, override: nil, system: .dark, backgroundIsLight: true) == .dark)
        }
    }

    @Test
    func theOverrideWinsOverEveryKey() {
        for configured in WindowTheme.allCases {
            #expect(WindowTheme.scheme(configured: configured, override: .light, system: .dark, backgroundIsLight: false) == .light)
            #expect(WindowTheme.scheme(configured: configured, override: .dark, system: .light, backgroundIsLight: true) == .dark)
            #expect(WindowTheme.scheme(configured: configured, override: .system, system: .dark, backgroundIsLight: true) == .dark)
            #expect(WindowTheme.scheme(configured: configured, override: .system, system: .light, backgroundIsLight: false) == .light)
        }
    }

    /// The background is read only for `auto` with no override. The read
    /// goes to the app config, so it must not run where it is not needed.
    @Test
    func readsTheBackgroundOnlyForAuto() {
        var reads = 0
        func light() -> Bool {
            reads += 1
            return true
        }
        for configured in WindowTheme.allCases where configured != .auto {
            _ = WindowTheme.scheme(configured: configured, override: nil, system: .dark, backgroundIsLight: light())
        }
        _ = WindowTheme.scheme(configured: .auto, override: .dark, system: .dark, backgroundIsLight: light())
        #expect(reads == 0)
        _ = WindowTheme.scheme(configured: .auto, override: nil, system: .dark, backgroundIsLight: light())
        #expect(reads == 1)
    }
}
