import AppKit
import Foundation
@testable import Macterm
import Testing

/// The adaptive TUI tint is per window (#345).
///
/// It used to be one app-wide value, which was the same thing while Macterm
/// had one window. With several, every window wore whatever the focused one's
/// terminal had painted, and changed colour again as focus moved.
@MainActor
struct AdaptiveWindowTintTests {
    private let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
    private let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)

    /// Leaves no tint behind for the next test — `GhosttyApp` is a singleton.
    private func withWindows(_ body: (NSWindow, NSWindow) -> Void) {
        let a = NSWindow()
        let b = NSWindow()
        defer {
            GhosttyApp.shared.forgetAdaptiveBackgroundColor(for: a)
            GhosttyApp.shared.forgetAdaptiveBackgroundColor(for: b)
        }
        body(a, b)
    }

    @Test
    func a_tint_applies_only_to_the_window_it_was_sampled_from() {
        withWindows { a, b in
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(red, for: a)

            #expect(GhosttyApp.shared.effectiveBackgroundColor(for: a).isVisuallyEqual(to: red))
            // The other window shows the configured theme, not a colour its
            // own terminal never painted.
            #expect(
                GhosttyApp.shared.effectiveBackgroundColor(for: b)
                    .isVisuallyEqual(to: GhosttyApp.shared.backgroundColor)
            )
        }
    }

    @Test
    func two_windows_hold_different_tints_at_once() {
        withWindows { a, b in
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(red, for: a)
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(blue, for: b)

            #expect(GhosttyApp.shared.effectiveBackgroundColor(for: a).isVisuallyEqual(to: red))
            #expect(GhosttyApp.shared.effectiveBackgroundColor(for: b).isVisuallyEqual(to: blue))
        }
    }

    @Test
    func clearing_one_window_leaves_the_others_tint() {
        withWindows { a, b in
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(red, for: a)
            GhosttyApp.shared.adoptAdaptiveBackgroundColor(blue, for: b)

            GhosttyApp.shared.adoptAdaptiveBackgroundColor(nil, for: a)

            #expect(
                GhosttyApp.shared.effectiveBackgroundColor(for: a)
                    .isVisuallyEqual(to: GhosttyApp.shared.backgroundColor)
            )
            #expect(GhosttyApp.shared.effectiveBackgroundColor(for: b).isVisuallyEqual(to: blue))
        }
    }

    @Test
    func a_closed_windows_tint_is_dropped() {
        // Entries are keyed on a weak window reference, so a closed window
        // must not keep a tint alive for the life of the app run.
        let window = NSWindow()
        GhosttyApp.shared.adoptAdaptiveBackgroundColor(red, for: window)
        GhosttyApp.shared.forgetAdaptiveBackgroundColor(for: window)

        #expect(
            GhosttyApp.shared.effectiveBackgroundColor(for: window)
                .isVisuallyEqual(to: GhosttyApp.shared.backgroundColor)
        )
    }

    @Test
    func no_window_means_the_configured_background() {
        // Chrome with no window to speak of must never borrow a tint.
        #expect(
            GhosttyApp.shared.effectiveBackgroundColor(for: nil)
                .isVisuallyEqual(to: GhosttyApp.shared.backgroundColor)
        )
    }
}
