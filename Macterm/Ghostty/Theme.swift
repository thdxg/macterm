import AppKit
import SwiftUI

/// All UI colors derived from the ghostty config. No hardcoded colors.
enum MactermTheme {
    @MainActor
    static var bg: Color { Color(nsColor: GhosttyApp.shared.backgroundColor) }
    @MainActor
    static var nsBg: NSColor { GhosttyApp.shared.backgroundColor }
    /// Background tinted by `Preferences.shared.windowOpacity`. Use for
    /// SwiftUI chrome that should follow window transparency (sidebar,
    /// palette, search bar). `bg`/`nsBg` stay opaque for callers that need
    /// a known-solid base color.
    @MainActor
    static var bgWithOpacity: Color {
        Color(nsColor: GhosttyApp.shared.backgroundColor.withAlphaComponent(Preferences.shared.windowOpacity))
    }

    @MainActor
    static var fg: Color { Color(nsColor: GhosttyApp.shared.foregroundColor) }
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

    /// A translucent overlay that dims an unfocused pane. Derived from the
    /// theme foreground (inverted vs the terminal bg) rather than a fixed
    /// black, so it reads correctly on light themes too.
    @MainActor
    static var dimOverlay: Color { colorScheme == .light ? fgAlpha(0.12) : Color.black.opacity(0.2) }

    @MainActor
    static var colorScheme: ColorScheme {
        let bg = GhosttyApp.shared.backgroundColor
        guard let srgb = bg.usingColorSpace(.sRGB) else { return .dark }
        let luminance = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        return luminance > 0.5 ? .light : .dark
    }

    @MainActor
    private static func fgAlpha(_ alpha: CGFloat) -> Color {
        Color(nsColor: GhosttyApp.shared.foregroundColor.withAlphaComponent(alpha))
    }
}
