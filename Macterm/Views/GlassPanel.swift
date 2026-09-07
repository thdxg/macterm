import SwiftUI

/// The floating-panel chrome shared by every transient overlay the app puts
/// over the terminal (command palette, tab switcher): liquid glass on
/// macOS 26, the closest native material below it, plus the hairline border
/// and drop shadow that make it read as a native floating surface rather
/// than a view drawn inside the window.
///
/// One modifier rather than a copy per overlay, so a new overlay can't drift
/// from the palette's look — the palette's radius (16) matches the macOS
/// Tahoe window corner radius, and anything floating beside it must too.
extension View {
    func glassPanel(cornerRadius: CGFloat = GlassPanelMetrics.cornerRadius) -> some View {
        glassPanelBackground(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MactermTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
    }

    /// Liquid glass on macOS 26; the closest native material on older systems.
    @ViewBuilder
    func glassPanelBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

enum GlassPanelMetrics {
    /// Matches the macOS Tahoe window corner radius.
    static let cornerRadius: CGFloat = 16
}
