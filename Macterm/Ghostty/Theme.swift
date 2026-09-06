import AppKit
import SwiftUI

/// All UI colors derived from the ghostty config. No hardcoded colors.
enum MactermTheme {
    @MainActor
    static var bg: Color { Color(nsColor: nsBg) }
    @MainActor
    static var nsBg: NSColor { GhosttyApp.shared.effectiveBackgroundColor }
    /// The configured theme background, never the transient adaptive tint.
    /// Window chrome that is not the window the tint was sampled from has to
    /// use this: the tint belongs to one window's terminal, and painting it
    /// onto another (the quick terminal panel) shows a foreign color until the
    /// next sample takes it away again.
    @MainActor
    static var nsConfiguredBg: NSColor { GhosttyApp.shared.backgroundColor }
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

    /// A project's color tag. System colors rather than the ghostty palette —
    /// see `ProjectColor` for why deriving them from the theme was wrong.
    @MainActor
    static func color(for projectColor: ProjectColor) -> Color {
        switch projectColor {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    /// Scrollbar search-tick colors (NSColor: drawn by an AppKit overlay),
    /// mirroring the renderer's search highlight backgrounds
    /// (`search-background` / `search-selected-background`) so the ticks read
    /// as the same yellow/orange as the highlighted text in the terminal.
    @MainActor
    static var nsSearchTick: NSColor {
        nsColor(SearchHighlightColors.matchBackground(inConfigText: MactermConfig.userGhosttyConfigText()))
    }

    @MainActor
    static var nsSearchTickSelected: NSColor {
        nsColor(SearchHighlightColors.selectedBackground(inConfigText: MactermConfig.userGhosttyConfigText()))
    }

    private static func nsColor(_ rgb: SearchHighlightColors.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// The translucent overlay that dims an unfocused split pane, honoring the
    /// user's ghostty `unfocused-split-opacity` / `unfocused-split-fill` with
    /// Ghostty.app's exact semantics. The fill defaults to the theme
    /// background, so the pane fades toward the background — which reads
    /// correctly on light themes too, where dimming toward black would not.
    @MainActor
    static var dimOverlay: Color {
        let app = GhosttyApp.shared
        return Color(nsColor: app.unfocusedSplitFill.withAlphaComponent(app.unfocusedSplitDimOpacity))
    }

    /// Scene-level light/dark scheme. Follows ONLY the resolved config theme,
    /// never the transient adaptive tint: `.preferredColorScheme` applies to
    /// every scene — including the Settings window — and flapping it at
    /// runtime destabilizes SwiftUI's window management (the closed Settings
    /// window reopens on app activation, and the WindowGroup window loses the
    /// cached identity that gates every hotkey). In-window chrome adapts
    /// through `nsBg`/`nsFg` instead, which are window-scoped.
    @MainActor
    static var colorScheme: ColorScheme {
        GhosttyApp.shared.backgroundColor.prefersDarkForeground ? .light : .dark
    }

    @MainActor
    private static func fgAlpha(_ alpha: CGFloat) -> Color {
        Color(nsColor: nsFg.withAlphaComponent(alpha))
    }
}
