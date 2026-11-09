import Foundation

/// The user's ghostty `window-theme`, and the `set_window_theme` action that
/// overrides it for the session. Together they decide the light or dark
/// scheme of the app (`GhosttyApp.windowScheme`): the chrome, and the scheme
/// of each surface, which picks the side of a `theme = light:X,dark:Y` split.
///
/// The rule is Ghostty.app's (`NSAppearance(ghosttyConfig:)` and
/// `AppDelegate.setAppearance` in upstream `macos/`):
///
/// - `light` and `dark` set the scheme.
/// - `system` follows macOS. `ghostty` is a GTK value: on macOS it sets no
///   appearance, so it follows macOS too.
/// - `auto`, ghostty's default, follows the luminosity of the terminal
///   background. libghostty changes `auto` to `system` when the theme is a
///   light/dark split with two different sides, so the read value is
///   already `system` there.
/// - The action's `light`, `dark` and `system` win over the key until the
///   action's `config` clears them. Ghostty keeps the override in memory
///   only, across config reloads.
///
/// Not followed: upstream's `macos-titlebar-style = tabs|transparent` rule
/// for terminal windows. Macterm has no such titlebar styles.
///
/// The raw values are ghostty's own tag names (`WindowTheme` in
/// `src/config/Config.zig`), which is what `ghostty_config_get` hands back
/// for the key, so they are a wire contract with libghostty.
enum WindowTheme: String, CaseIterable {
    case auto
    case system
    case light
    case dark
    case ghostty

    /// An enum key, read as its tag name.
    static let key = GhosttyConfigKey.tag("window-theme")

    /// The session override that `set_window_theme` sets. Its `config` value
    /// is no override (nil).
    enum Override: Equatable {
        case system
        case light
        case dark
    }

    /// An unset, unreadable or unknown value is `auto`, ghostty's default,
    /// so a failed read keeps the scheme as it was before this key counted.
    static func resolve(configValue: String?) -> WindowTheme {
        guard let raw = configValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .auto
        }
        return WindowTheme(rawValue: raw.lowercased()) ?? .auto
    }

    /// The scheme of the app. `backgroundIsLight` is read only for `auto`
    /// with no override.
    static func scheme(
        configured: WindowTheme,
        override: Override?,
        system: ThemeResolver.Scheme,
        backgroundIsLight: @autoclosure () -> Bool
    ) -> ThemeResolver.Scheme {
        switch override {
        case .light: return .light
        case .dark: return .dark
        case .system: return system
        case nil: break
        }
        switch configured {
        case .light: return .light
        case .dark: return .dark
        case .system,
             .ghostty: return system
        case .auto: return backgroundIsLight() ? .light : .dark
        }
    }
}
