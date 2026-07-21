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

/// Which `NSGlassEffectView.Style` the liquid-glass window background uses.
/// Maps to AppKit's `.regular` / `.clear` (see `WindowAppearance`).
enum WindowGlassStyle: String, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        }
    }
}

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Macterm primarily stores app-shaped state here (window opacity/blur, quick
/// terminal, hotkeys, etc.). The optional terminal-background override is the
/// one user-requested Ghostty setting Macterm owns; `MactermConfig` writes it
/// into the last-wins wrapper only while that mode is selected.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences(defaults: defaults)

    /// The UserDefaults domain all Macterm state persists to — `.standard` in
    /// the app, a wiped side suite under test (see `resolveDefaults()`). Use
    /// this instead of `UserDefaults.standard` anywhere the app reads or
    /// writes defaults directly (project recency, hotkey overrides), so those
    /// writes get the same test isolation as `Preferences` properties.
    /// `nonisolated(unsafe)` because the SDK doesn't mark `UserDefaults`
    /// Sendable even though it's documented thread-safe.
    nonisolated(unsafe) static let defaults: UserDefaults = resolveDefaults()

    // MARK: - Layout / appearance

    var autoTilingEnabled: Bool {
        didSet {
            defaults.set(autoTilingEnabled, forKey: Keys.autoTiling)
            // Legacy notification — listeners predate Preferences.
            NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
        }
    }

    /// Start every tab of the focused project immediately (off-screen) rather
    /// than only the active tab. Defaults to on.
    var eagerlyStartProjectTabs: Bool {
        didSet { defaults.set(eagerlyStartProjectTabs, forKey: Keys.eagerlyStartProjectTabs) }
    }

    /// Multiplier applied to terminal scroll wheel / trackpad row deltas.
    var terminalScrollSpeed: Double {
        didSet { defaults.set(terminalScrollSpeed, forKey: Keys.terminalScrollSpeed) }
    }

    /// How dark the overlay on an unfocused split pane gets (0–0.8, 0 = no dimming).
    /// Capped below 1 so an unfocused pane is never fully black.
    var paneDimOpacity: Double {
        didSet { defaults.set(paneDimOpacity, forKey: Keys.paneDimOpacity) }
    }

    // MARK: - Sidebar icons

    var projectIconSymbol: String {
        didSet { defaults.set(projectIconSymbol, forKey: Keys.projectIconSymbol) }
    }

    var tabIconSymbol: String {
        didSet { defaults.set(tabIconSymbol, forKey: Keys.tabIconSymbol) }
    }

    /// Replace a tab's icon with the running AI agent's logo (Claude Code,
    /// Codex, …) while one holds the pane's foreground. On by default.
    var showAgentIcons: Bool {
        didSet { defaults.set(showAgentIcons, forKey: Keys.showAgentIcons) }
    }

    /// Show a status badge over each tab icon: a spinner while a command is
    /// running (replacing the icon) and a small status dot when a command has
    /// finished and awaits attention. Off = pure icons, no status tracking.
    var showTabStatusIndicator: Bool {
        didSet { defaults.set(showTabStatusIndicator, forKey: Keys.showTabStatusIndicator) }
    }

    var showNewProjectButton: Bool {
        didSet { defaults.set(showNewProjectButton, forKey: Keys.showNewProjectButton) }
    }

    /// When true, quitting Macterm kills every pane's zmx session so nothing
    /// keeps running in the background. Default off — session persistence
    /// (shells survive quit and reattach on relaunch) is the point, so quit
    /// detaches rather than terminates. Macterm-side only; never touches the
    /// ghostty config pipeline.
    var terminateSessionsOnQuit: Bool {
        didSet { defaults.set(terminateSessionsOnQuit, forKey: Keys.terminateSessionsOnQuit) }
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

    /// Upper bound for `paneDimOpacity` — a fully black overlay reads as broken, not dim.
    static let maxPaneDimOpacity: Double = 0.8

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
            notifyWindowAppearanceChanged()
        }
    }

    /// CGSSetWindowBackgroundBlurRadius value (0–100). 0 = no blur.
    var windowBlurRadius: Int {
        didSet {
            defaults.set(windowBlurRadius, forKey: Keys.windowBlurRadius)
            notifyWindowAppearanceChanged()
        }
    }

    /// Use the macOS 26 liquid-glass material (`NSGlassEffectView`) for the
    /// translucent window background instead of the legacy CGS Gaussian blur.
    /// Only has any effect when `windowOpacity < 1` — at full opacity the
    /// window is solid and neither blur nor glass is visible. When enabled the
    /// `windowBlurRadius` slider is ignored; the glass material defines its own
    /// look.
    var windowGlassEnabled: Bool {
        didSet {
            defaults.set(windowGlassEnabled, forKey: Keys.windowGlassEnabled)
            notifyWindowAppearanceChanged()
        }
    }

    /// Which liquid-glass material to use when `windowGlassEnabled` is on.
    /// `.regular` is frostier/more tinted; `.clear` is more transparent. No
    /// effect unless glass is enabled.
    var windowGlassStyle: WindowGlassStyle {
        didSet {
            defaults.set(windowGlassStyle.rawValue, forKey: Keys.windowGlassStyle)
            notifyWindowAppearanceChanged()
        }
    }

    /// Match an opaque color painted across most of a terminal surface. A lone
    /// pane may tint the window; split panes are adapted independently. Off by
    /// default: the user's Ghostty theme remains the source of truth unless
    /// they explicitly opt in.
    var adaptiveTerminalChromeEnabled: Bool {
        didSet {
            defaults.set(adaptiveTerminalChromeEnabled, forKey: Keys.adaptiveTerminalChromeEnabled)
            if adaptiveTerminalChromeEnabled {
                AdaptiveTerminalChrome.shared.preferenceDidEnable()
            } else {
                AdaptiveTerminalChrome.shared.preferenceDidDisable()
            }
            notifyWindowAppearanceChanged()
        }
    }

    // MARK: - Ghostty config

    /// Keep the user's Ghostty background as the source of truth, or replace
    /// it with Macterm's persisted custom color in the last-wins config layer.
    var terminalBackgroundSource: TerminalBackgroundSource {
        didSet {
            defaults.set(terminalBackgroundSource.rawValue, forKey: Keys.terminalBackgroundSource)
            notifyConfigChanged()
        }
    }

    /// The remembered override color. It remains persisted when Ghostty config
    /// mode is selected so switching away and back does not discard the user's
    /// choice. Color-picker updates are debounced to avoid reloading every live
    /// terminal surface for every intermediate drag event.
    var terminalBackgroundOverrideColor: TerminalBackgroundColor {
        didSet {
            defaults.set(terminalBackgroundOverrideColor.hex, forKey: Keys.terminalBackgroundOverrideColor)
            scheduleConfigChanged()
        }
    }

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
        pendingConfigReload?.cancel()
        pendingConfigReload = nil
        MactermConfig.shared.regenerate()
        GhosttyApp.shared.reloadConfig()
    }

    private func scheduleConfigChanged() {
        pendingConfigReload?.cancel()
        pendingConfigReload = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.notifyConfigChanged()
        }
    }

    /// Notify observers that a WINDOW-APPEARANCE pref (opacity/blur/glass)
    /// changed, WITHOUT regenerating the ghostty config or reloading libghostty.
    /// Those values don't appear in the regenerated files (`background-opacity`
    /// is pinned to 0 unconditionally) — `WindowAppearance.sync` reads them
    /// straight from Preferences. Previously these setters ran the full
    /// `notifyConfigChanged()` (two file writes + a whole-config libghostty
    /// reload) purely to piggy-back on the `.mactermConfigDidChange` post it
    /// ends with — heavyweight, and fired continuously while dragging a slider.
    private func notifyWindowAppearanceChanged() {
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
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

    /// The unit-test suite runs hosted inside the debug app, so
    /// `UserDefaults.standard` there is the developer's real
    /// `com.thdxg.macterm.debug` domain — a test mutating a preference (even
    /// indirectly, e.g. `AppState.activeProjectID`'s write-through) would
    /// corrupt the app they use day to day. Under a test run, back the app's
    /// defaults with a wiped side suite instead so writes never leave the run.
    nonisolated private static func resolveDefaults() -> UserDefaults {
        guard isTestRun else { return .standard }
        let suiteName = appBundleID + ".tests"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        // Wipe residue from previous runs so every test run starts clean.
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// True when this process is an XCTest / Swift Testing host. Detected via
    /// the runner's environment (`XCTestConfigurationFilePath`,
    /// `XCTestSessionIdentifier`, … — the exact key varies by Xcode version)
    /// rather than a loaded-class check: the test bundle injects only after app
    /// launch, but the environment is set from process start, so this is
    /// correct however early `shared` is first touched.
    nonisolated private static var isTestRun: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var pendingConfigReload: Task<Void, Never>?

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        autoTilingEnabled = defaults.bool(forKey: Keys.autoTiling)
        eagerlyStartProjectTabs = (defaults.object(forKey: Keys.eagerlyStartProjectTabs) as? Bool) ?? true
        terminalScrollSpeed = Self.clampScrollSpeed(defaults.double(forKey: Keys.terminalScrollSpeed), fallback: 1.0)
        paneDimOpacity = Self.clampPaneDimOpacity(
            (defaults.object(forKey: Keys.paneDimOpacity) as? Double) ?? 0.2
        )
        windowOpacity = (defaults.object(forKey: Keys.windowOpacity) as? Double) ?? 1.0
        windowBlurRadius = defaults.integer(forKey: Keys.windowBlurRadius)
        windowGlassEnabled = defaults.object(forKey: Keys.windowGlassEnabled) as? Bool ?? false
        windowGlassStyle = (defaults.string(forKey: Keys.windowGlassStyle))
            .flatMap(WindowGlassStyle.init(rawValue:)) ?? .regular
        adaptiveTerminalChromeEnabled = defaults.object(forKey: Keys.adaptiveTerminalChromeEnabled) as? Bool ?? false
        terminalBackgroundSource = defaults.string(forKey: Keys.terminalBackgroundSource)
            .flatMap(TerminalBackgroundSource.init(rawValue:)) ?? .ghosttyConfig
        terminalBackgroundOverrideColor = defaults.string(forKey: Keys.terminalBackgroundOverrideColor)
            .flatMap(TerminalBackgroundColor.init(hex:)) ?? .defaultValue
        userGhosttyConfigPath = defaults.string(forKey: Keys.userGhosttyConfigPath) ?? "~/.config/ghostty/config"
        quickTerminalEnabled = defaults.object(forKey: Keys.quickTerminalEnabled) as? Bool ?? true
        quickTerminalWidthFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalWidth), fallback: 0.6)
        quickTerminalHeightFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalHeight), fallback: 0.5)
        activeProjectID = (defaults.string(forKey: Keys.activeProjectID)).flatMap(UUID.init)
        projectIconSymbol = defaults.string(forKey: Keys.projectIconSymbol) ?? "folder"
        tabIconSymbol = defaults.string(forKey: Keys.tabIconSymbol) ?? "terminal"
        showAgentIcons = defaults.object(forKey: Keys.showAgentIcons) as? Bool ?? true
        showTabStatusIndicator = defaults.object(forKey: Keys.showTabStatusIndicator) as? Bool ?? false
        showNewProjectButton = defaults.object(forKey: Keys.showNewProjectButton) as? Bool ?? true
        terminateSessionsOnQuit = defaults.object(forKey: Keys.terminateSessionsOnQuit) as? Bool ?? false
        tabSwitcherVisibility = (defaults.string(forKey: Keys.tabSwitcherVisibility))
            .flatMap(TabSwitcherVisibility.init(rawValue:)) ?? .whenMultiple
        Self.runOneTimeMigrations(defaults: defaults)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    private static func clampPaneDimOpacity(_ v: Double) -> Double {
        max(0.0, min(maxPaneDimOpacity, v))
    }

    private static func clampScrollSpeed(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.25, min(3.0, v))
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
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let autoTiling = "macterm.autoTiling.enabled"
        static let eagerlyStartProjectTabs = "macterm.eagerlyStartProjectTabs.enabled"
        static let terminalScrollSpeed = "macterm.terminal.scrollSpeed"
        static let paneDimOpacity = "macterm.pane.dimOpacity"
        static let windowOpacity = "macterm.window.opacity"
        static let windowBlurRadius = "macterm.window.blurRadius"
        static let windowGlassEnabled = "macterm.window.glassEnabled"
        static let windowGlassStyle = "macterm.window.glassStyle"
        static let adaptiveTerminalChromeEnabled = "macterm.window.adaptiveTerminalChromeEnabled"
        static let terminalBackgroundSource = "macterm.terminal.backgroundSource"
        static let terminalBackgroundOverrideColor = "macterm.terminal.backgroundOverrideColor"
        static let userGhosttyConfigPath = "macterm.ghostty.userConfigPath"
        static let quickTerminalEnabled = "macterm.quickTerminal.enabled"
        static let quickTerminalWidth = "macterm.quickTerminal.width"
        static let quickTerminalHeight = "macterm.quickTerminal.height"
        static let activeProjectID = "macterm.activeProjectID"
        static let projectIconSymbol = "macterm.sidebar.projectIcon"
        static let tabIconSymbol = "macterm.sidebar.tabIcon"
        static let showAgentIcons = "macterm.sidebar.showAgentIcons"
        static let showTabStatusIndicator = "macterm.sidebar.showTabStatusIndicator"
        static let showNewProjectButton = "macterm.sidebar.showNewProjectButton"
        static let terminateSessionsOnQuit = "macterm.session.terminateOnQuit"
        static let tabSwitcherVisibility = "macterm.toolbar.tabSwitcherVisibility"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
    }
}
