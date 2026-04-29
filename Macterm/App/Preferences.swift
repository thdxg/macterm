import AppKit
import Foundation
import Observation

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Before: settings were scattered across `UserDefaults.standard.set/get`
/// calls in SettingsView, ad-hoc wrappers like `AutoTilePreference`, and
/// `@AppStorage` in views. Different views used different access patterns,
/// and observers couldn't tell that a setting had changed without bespoke
/// `NotificationCenter` glue.
///
/// Now: every call site reads/writes through `Preferences.shared.x`. Changes
/// notify via Swift's Observation macro, and legacy `NotificationCenter`
/// signals (e.g. `.autoTilingEnabledDidChange`) are still posted so older
/// objects that observe them keep working.
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

    // MARK: - Quick terminal

    var quickTerminalEnabled: Bool {
        didSet {
            defaults.set(quickTerminalEnabled, forKey: Keys.quickTerminalEnabled)
            guard quickTerminalEnabled != oldValue else { return }
            // Legacy notification — QuickTerminalService observes this to
            // (un)register its global Carbon hot key at runtime.
            NotificationCenter.default.post(name: .quickTerminalEnabledDidChange, object: nil)
        }
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
        quickTerminalEnabled = defaults.object(forKey: Keys.quickTerminalEnabled) as? Bool ?? true
        quickTerminalWidthFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalWidth), fallback: 0.6)
        quickTerminalHeightFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalHeight), fallback: 0.5)
        activeProjectID = (defaults.string(forKey: Keys.activeProjectID)).flatMap(UUID.init)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let autoTiling = "macterm.autoTiling.enabled"
        static let quickTerminalEnabled = "macterm.quickTerminal.enabled"
        static let quickTerminalWidth = "macterm.quickTerminal.width"
        static let quickTerminalHeight = "macterm.quickTerminal.height"
        static let activeProjectID = "macterm.activeProjectID"
    }
}
