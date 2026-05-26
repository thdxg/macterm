import AppKit
import Foundation
import Observation

/// When the numbered tab switcher in the title bar is shown.
enum TabSwitcherVisibility: String, CaseIterable, Identifiable {
    case always
    case whenMultiple = "when_multiple"
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: "Always"
        case .whenMultiple: "When multiple tabs"
        case .hidden: "Hidden"
        }
    }
}

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Macterm only stores app-shaped state here (window opacity/blur, quick
/// terminal, hotkeys, etc.). Anything that's a ghostty config setting lives
/// in the user's Ghostty config instead — see `MactermConfig` for the wrapper
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

    // MARK: - Sidebar icons

    var projectIconSymbol: String {
        didSet { defaults.set(projectIconSymbol, forKey: Keys.projectIconSymbol) }
    }

    var tabIconSymbol: String {
        didSet { defaults.set(tabIconSymbol, forKey: Keys.tabIconSymbol) }
    }

    var showNewProjectButton: Bool {
        didSet { defaults.set(showNewProjectButton, forKey: Keys.showNewProjectButton) }
    }

    // MARK: - Toolbar

    var tabSwitcherVisibility: TabSwitcherVisibility {
        didSet { defaults.set(tabSwitcherVisibility.rawValue, forKey: Keys.tabSwitcherVisibility) }
    }

    /// Sentinel for "no icon" — sidebar rows skip the leading glyph when set.
    static let noIcon = "none"
    /// Sentinels for "show 1-based top-down position" — sidebar rows render a number glyph.
    /// Each variant picks a different SF Symbols container (or plain text) around the digit.
    static let numberIconCircleFill = "number.circle.fill"
    static let numberIconCircle = "number.circle"
    static let numberIconSquareFill = "number.square.fill"
    static let numberIconSquare = "number.square"
    static let numberIconPlain = "number.plain"

    static let numberIconChoices: Set<String> = [
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
    ]

    /// Curated SF Symbols offered in Settings — keeps users from typing invalid names.
    static let projectIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "folder",
        "folder.fill",
        "briefcase",
        "shippingbox",
        "cube",
        "hammer",
    ]
    static let tabIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "terminal",
        "chevron.right",
        "chevron.compact.right",
        "circle.fill",
        "circle",
        "command",
    ]

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

    /// Path to the user's Ghostty config. Empty string = don't load any user
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
        projectIconSymbol = defaults.string(forKey: Keys.projectIconSymbol) ?? "folder"
        tabIconSymbol = defaults.string(forKey: Keys.tabIconSymbol) ?? "terminal"
        showNewProjectButton = defaults.object(forKey: Keys.showNewProjectButton) as? Bool ?? true
        tabSwitcherVisibility = (defaults.string(forKey: Keys.tabSwitcherVisibility))
            .flatMap(TabSwitcherVisibility.init(rawValue:)) ?? .whenMultiple
        Self.runOneTimeMigrations(defaults: defaults)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    /// Pre-v2 builds stored theme/font/option-as-alt in UserDefaults. Those
    /// settings now live entirely in the user's Ghostty config, so the keys
    /// are dead. Drop them so `defaults read com.thdxg.macterm` is clean
    /// and there's no risk of resurrecting the old values if someone wires
    /// them back up later.
    private static func runOneTimeMigrations(defaults: UserDefaults) {
        if !defaults.bool(forKey: Keys.migrationV2GhosttyConfigOwned) {
            defaults.removeObject(forKey: "macterm.appearance.theme")
            defaults.removeObject(forKey: "macterm.appearance.fontFamily")
            defaults.removeObject(forKey: "macterm.appearance.fontSize")
            defaults.removeObject(forKey: "macterm.input.optionAsAlt")
            defaults.set(true, forKey: Keys.migrationV2GhosttyConfigOwned)
        }
        // The original "number" sentinel was replaced by per-variant tokens.
        // Map any user who was on it to the filled-circle variant so their
        // sidebar doesn't silently lose its number icons on upgrade.
        for key in [Keys.projectIconSymbol, Keys.tabIconSymbol] where defaults.string(forKey: key) == "number" {
            defaults.set(numberIconCircleFill, forKey: key)
        }
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
        static let projectIconSymbol = "macterm.sidebar.projectIcon"
        static let tabIconSymbol = "macterm.sidebar.tabIcon"
        static let showNewProjectButton = "macterm.sidebar.showNewProjectButton"
        static let tabSwitcherVisibility = "macterm.toolbar.tabSwitcherVisibility"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
    }
}
