import AppKit

/// The Dock-badge half of ghostty's `bell-features = attention`.
///
/// Ghostty.app badges its Dock tile with the number of WINDOWS holding an
/// unacknowledged bell; Macterm's unit is the TAB, because tabs live in a
/// sidebar rather than in windows and a tab is what the user goes and looks
/// at. The derivation is pure — tab bell states plus the feature set in, a
/// label out — and `apply` is the one place the AppKit write happens.
/// `AppState.syncDockBadge` glues the two together.
enum BellBadge {
    /// Ghostty's cap: past this the label reads `99+`.
    static let cap = 99

    /// How many of `tabs` carry an unacknowledged bell. A tab counts once no
    /// matter how many of its panes rang.
    @MainActor
    static func tabCount(_ tabs: some Sequence<TerminalTab>) -> Int {
        tabs.reduce(0) { $0 + ($1.hasUnacknowledgedBell ? 1 : 0) }
    }

    /// The badge text for `bellTabCount` ringing tabs under `features`: nil —
    /// no badge — unless `attention` is on AND something rang. The feature
    /// gate lives here rather than at the write site so a config reload that
    /// drops `attention` clears an existing badge by the same rule that would
    /// have refused to show it.
    static func label(bellTabCount: Int, features: GhosttyApp.BellFeatures) -> String? {
        guard features.contains(.attention), bellTabCount > 0 else { return nil }
        return bellTabCount > cap ? "\(cap)+" : String(bellTabCount)
    }

    /// The single AppKit write. `NSApp` is nil while the SwiftUI `App` struct
    /// is being built, and a badge before the Dock tile exists is meaningless.
    @MainActor
    static func apply(_ label: String?) {
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = label
        app.dockTile.display()
    }
}
