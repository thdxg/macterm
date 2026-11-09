import SwiftUI

/// The floating-panel chrome shared by every panel the app puts over the
/// terminal (command palette, tab switcher, the Project Insights panel and
/// the overlay sidebar peek): liquid glass on macOS 26, the closest native
/// material below it, plus the hairline border and drop shadow that make it
/// read as a native floating surface rather than a view drawn inside the
/// window.
///
/// One modifier rather than a copy per panel, so a new panel can't drift
/// from the others. A centered overlay takes the palette's radius (16), the
/// macOS Tahoe window corner radius. A full-height side panel takes
/// `GlassPanelMetrics.sidePanelCornerRadius`.
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
    /// The corner of a full-height side panel: Project Insights on the
    /// trailing side, the overlay sidebar peek on the leading side. One
    /// value, so the two panels cannot drift apart.
    static let sidePanelCornerRadius: CGFloat = 22
    /// The gap between a side panel and the edges of the window content,
    /// below the toolbar.
    static let sidePanelInset: CGFloat = 10
}
