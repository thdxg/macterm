import AppKit
@testable import Macterm
import Observation
import SwiftUI
import Testing

@MainActor
private final class ObservationFlag {
    var wasInvalidated = false
}

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

    /// Regression: the quick terminal panel is a separate window whose panes
    /// carry their own adaptive fills, but it was painted with the MAIN
    /// window's tint on the frame it was ordered front — a flash of the
    /// focused tab's TUI background that the next sample took away again.
    /// Window chrome that does not own the tint reads the configured
    /// background instead.
    @Test
    func configuredBackgroundIgnoresTheAdaptiveTint() {
        let configured = MactermTheme.nsConfiguredBg
        let tint: NSColor = configured.isVisuallyEqual(to: .black) ? .white : .black

        let previous = GhosttyApp.shared.adaptiveBackgroundColor
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(tint)
        defer { GhosttyApp.shared.adoptAdaptiveBackgroundColor(previous) }

        #expect(MactermTheme.nsBg.isVisuallyEqual(to: tint))
        #expect(MactermTheme.nsConfiguredBg.isVisuallyEqual(to: configured))
    }

    /// Regression: SwiftUI reaches the observable adaptive tint through the
    /// static `MactermTheme.nsBg` accessor. Keep that dependency intact so a
    /// tint change invalidates in-window chrome without pretending the user's
    /// persisted Ghostty configuration changed.
    @Test
    func adaptiveTintInvalidatesThemeBackgroundObservation() {
        let previous = GhosttyApp.shared.adaptiveBackgroundColor
        let replacement = previous?.isVisuallyEqual(to: .black) == true ? NSColor.white : .black
        defer { GhosttyApp.shared.adoptAdaptiveBackgroundColor(previous) }

        let flag = ObservationFlag()
        withObservationTracking {
            _ = MactermTheme.nsBg
        } onChange: {
            MainActor.assumeIsolated {
                flag.wasInvalidated = true
            }
        }

        GhosttyApp.shared.adoptAdaptiveBackgroundColor(replacement)

        #expect(flag.wasInvalidated)
    }
}
