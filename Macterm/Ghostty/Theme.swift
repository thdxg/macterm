import AppKit
import SwiftUI

/// All UI colors derived from the ghostty config. No hardcoded colors.
enum MactermTheme {
    @MainActor
    static var bg: Color { Color(nsColor: GhosttyApp.shared.backgroundColor) }
    @MainActor
    static var nsBg: NSColor { GhosttyApp.shared.backgroundColor }
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
    static var terminalBg: Color {
        Color(nsColor: GhosttyApp.shared.backgroundColor.withAlphaComponent(GhosttyApp.shared.backgroundOpacity))
    }

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
