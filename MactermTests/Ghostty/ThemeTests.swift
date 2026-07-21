import AppKit
@testable import Macterm
import SwiftUI
import Testing

@MainActor
struct ThemeTests {
    /// Regression: the adaptive tint feeding `.preferredColorScheme` made the
    /// app-wide scheme flap whenever a full-screen TUI's background was
    /// adopted or cleared, which destabilized SwiftUI window management (the
    /// closed Settings window reopened on every app activation, and hotkeys
    /// broke because the WindowGroup window lost its cached identity).
    @Test
    func colorSchemeIgnoresTheTransientAdaptiveTint() {
        let configScheme = MactermTheme.colorScheme
        let opposite: NSColor = configScheme == .dark ? .white : .black

        let previous = GhosttyApp.shared.adaptiveBackgroundColor
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(opposite)
        defer { GhosttyApp.shared.adoptAdaptiveBackgroundColor(previous) }

        // The in-window chrome color follows the tint…
        #expect(MactermTheme.nsBg.isVisuallyEqual(to: opposite))
        // …but the scene-level scheme must not.
        #expect(MactermTheme.colorScheme == configScheme)
    }
}
