import AppKit
import Foundation
import Observation

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Macterm only stores app-shaped state here (window opacity/blur, quick
/// terminal, hotkeys, etc.). Anything that's a ghostty config setting lives
/// in the user's ghostty.conf instead — see `MactermConfig` for the wrapper
/// files Macterm generates around it.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    // MARK: - Layout / appearance

    var autoTilingEnabled: Bool {
        didSet {
            defaults.set(autoTilingEnabled, forKey: Keys.autoTiling)
            // Legacy notification — listeners predate Preferences.
            NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
        }
    }

    // MARK: - Window

    /// Macterm-painted window background opacity (0–1). Independent from
    /// ghostty's renderer — `macterm-overrides.conf` pins `background-opacity
    /// = 0` so ghostty draws fully transparent, then Macterm composites this
    /// translucency at the window level. Avoids the double-paint problem when
    /// both layers tint.
    var windowOpacity: Double {
        didSet {
            defaults.set(windowOpacity, forKey: Keys.windowOpacity)
            notifyConfigChanged()
        }
    }

    /// CGSSetWindowBackgroundBlurRadius value (0–100). 0 = no blur.
    var windowBlurRadius: Int {
        didSet {
            defaults.set(windowBlurRadius, forKey: Keys.windowBlurRadius)
            notifyConfigChanged()
        }
    }

    // MARK: - Ghostty config

    /// Path to the user's ghostty.conf. Empty string = don't load any user
    /// config (Macterm-defaults only). Tilde-expand via
    /// `expandedUserGhosttyConfigPath` at use sites.
    ///
    /// Note: this setter does NOT auto-reload, intentionally. Settings UI is
    /// the only writer and it calls `GhosttyApp.shared.reloadConfig()`
    /// directly so it can surface any errors (missing file, parse errors)
    /// in an alert. Other reloads happen silently.
    var userGhosttyConfigPath: String {
        didSet {
            defaults.set(userGhosttyConfigPath, forKey: Keys.userGhosttyConfigPath)
        }
    }

    /// `userGhosttyConfigPath` with leading `~` expanded to the home dir.
    /// Empty when the user has disabled loading by clearing the field.
    var expandedUserGhosttyConfigPath: String {
        guard !userGhosttyConfigPath.isEmpty else { return "" }
        return (userGhosttyConfigPath as NSString).expandingTildeInPath
    }

    /// Window-level appearance + libghostty reload. Both happen on the same
    /// notification so the renderer and the window chrome stay in sync.
    private func notifyConfigChanged() {
        MactermConfig.shared.regenerate()
        GhosttyApp.shared.reloadConfig()
    }

    // MARK: - Quick terminal

    var quickTerminalEnabled: Bool {
        didSet { defaults.set(quickTerminalEnabled, forKey: Keys.quickTerminalEnabled) }
    }

    /// Fraction of screen width (0–1).
    var quickTerminalWidthFraction: Double {
        didSet { defaults.set(quickTerminalWidthFraction, forKey: Keys.quickTerminalWidth) }
    }

    /// Fraction of screen height (0–1).
    var quickTerminalHeightFraction: Double {
        didSet { defaults.set(quickTerminalHeightFraction, forKey: Keys.quickTerminalHeight) }
    }

    // MARK: - Session

    /// Persisted so the app re-opens to the last-used project on launch.
    var activeProjectID: UUID? {
        didSet { defaults.set(activeProjectID?.uuidString, forKey: Keys.activeProjectID) }
    }

    // MARK: - Init

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoTilingEnabled = defaults.bool(forKey: Keys.autoTiling)
        windowOpacity = (defaults.object(forKey: Keys.windowOpacity) as? Double) ?? 1.0
        windowBlurRadius = defaults.integer(forKey: Keys.windowBlurRadius)
        userGhosttyConfigPath = defaults.string(forKey: Keys.userGhosttyConfigPath) ?? "~/.config/ghostty/config"
        quickTerminalEnabled = defaults.object(forKey: Keys.quickTerminalEnabled) as? Bool ?? true
        quickTerminalWidthFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalWidth), fallback: 0.6)
        quickTerminalHeightFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalHeight), fallback: 0.5)
        activeProjectID = (defaults.string(forKey: Keys.activeProjectID)).flatMap(UUID.init)
        Self.runOneTimeMigrations(defaults: defaults)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    /// Pre-v2 builds stored theme/font/option-as-alt in UserDefaults. Those
    /// settings now live entirely in the user's ghostty.conf, so the keys
    /// are dead. Drop them so `defaults read com.thdxg.macterm` is clean
    /// and there's no risk of resurrecting the old values if someone wires
    /// them back up later.
    private static func runOneTimeMigrations(defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.migrationV2GhosttyConfigOwned) else { return }
        defaults.removeObject(forKey: "macterm.appearance.theme")
        defaults.removeObject(forKey: "macterm.appearance.fontFamily")
        defaults.removeObject(forKey: "macterm.appearance.fontSize")
        defaults.removeObject(forKey: "macterm.input.optionAsAlt")
        defaults.set(true, forKey: Keys.migrationV2GhosttyConfigOwned)
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let autoTiling = "macterm.autoTiling.enabled"
        static let windowOpacity = "macterm.window.opacity"
        static let windowBlurRadius = "macterm.window.blurRadius"
        static let userGhosttyConfigPath = "macterm.ghostty.userConfigPath"
        static let quickTerminalEnabled = "macterm.quickTerminal.enabled"
        static let quickTerminalWidth = "macterm.quickTerminal.width"
        static let quickTerminalHeight = "macterm.quickTerminal.height"
        static let activeProjectID = "macterm.activeProjectID"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
    }
}
