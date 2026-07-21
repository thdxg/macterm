import AppKit
import SwiftUI

/// All UI colors derived from the ghostty config. No hardcoded colors.
enum MactermTheme {
    @MainActor
    static var bg: Color { Color(nsColor: nsBg) }
    @MainActor
    static var nsBg: NSColor { GhosttyApp.shared.effectiveBackgroundColor }
    /// Background tinted by `Preferences.shared.windowOpacity`. Use for
    /// SwiftUI chrome that should follow window transparency (sidebar,
    /// palette, search bar). `bg`/`nsBg` stay opaque for callers that need
    /// a known-solid base color.
    @MainActor
    static var bgWithOpacity: Color {
        Color(nsColor: nsBg.withAlphaComponent(Preferences.shared.windowOpacity))
    }

    @MainActor
    static var fg: Color { Color(nsColor: nsFg) }
    @MainActor
    static var fgMuted: Color { fgAlpha(0.65) }
    @MainActor
    static var fgDim: Color { fgAlpha(0.4) }
    @MainActor
    static var surface: Color { fgAlpha(0.08) }
    @MainActor
    static var border: Color { fgAlpha(0.12) }
    @MainActor
    static var hover: Color { fgAlpha(0.06) }
    @MainActor
    static var accent: Color { Color(nsColor: GhosttyApp.shared.accentColor) }
    @MainActor
    static var accentSoft: Color { Color(nsColor: GhosttyApp.shared.accentColor.withAlphaComponent(0.1)) }
    @MainActor
    static var terminalBg: Color { bg }

    @MainActor
    static var nsFg: NSColor {
        let preferred = GhosttyApp.shared.foregroundColor
        guard preferred.contrastRatio(with: nsBg) < 4.5 else { return preferred }
        return nsBg.contrastingMonochromeColor
    }

    /// Semantic status colors, mapped from the ghostty terminal palette so they
    /// track the user's theme instead of the fixed system `.yellow`/`.green`.
    /// Palette indices follow the ANSI convention: 2 = green, 3 = yellow.
    @MainActor
    static var warning: Color {
        GhosttyApp.shared.paletteColor(at: 3).map { Color(nsColor: $0) } ?? .yellow
    }

    @MainActor
    static var success: Color {
        GhosttyApp.shared.paletteColor(at: 2).map { Color(nsColor: $0) } ?? .green
    }

    /// Scrollbar search-tick colors (NSColor: drawn by an AppKit overlay),
    /// mirroring the renderer's search highlight backgrounds
    /// (`search-background` / `search-selected-background`) so the ticks read
    /// as the same yellow/orange as the highlighted text in the terminal.
    @MainActor
    static var nsSearchTick: NSColor {
        nsColor(SearchHighlightColors.matchBackground(inConfigText: userGhosttyConfigText()))
    }

    @MainActor
    static var nsSearchTickSelected: NSColor {
        nsColor(SearchHighlightColors.selectedBackground(inConfigText: userGhosttyConfigText()))
    }

    /// Same read as `MactermConfig.userGhosttyConfigText` — the search
    /// highlight keys live in the user's ghostty config, not ours.
    @MainActor
    private static func userGhosttyConfigText() -> String? {
        let path = Preferences.shared.expandedUserGhosttyConfigPath
        guard !path.isEmpty else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func nsColor(_ rgb: SearchHighlightColors.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// A translucent overlay that dims an unfocused pane, at the user-configured
    /// `opacity` (#156). Derived from the theme rather than a fixed black so it
    /// reads correctly on light themes too: on a light theme, dimming toward the
    /// (dark) foreground reduces contrast the way black does on a dark theme;
    /// on a dark theme, black is correct.
    @MainActor
    static func dimOverlay(opacity: Double) -> Color {
        colorScheme == .light ? fgAlpha(opacity) : Color.black.opacity(opacity)
    }

    @MainActor
    static var colorScheme: ColorScheme {
        nsBg.prefersDarkForeground ? .light : .dark
    }

    @MainActor
    private static func fgAlpha(_ alpha: CGFloat) -> Color {
        Color(nsColor: nsFg.withAlphaComponent(alpha))
    }
}
