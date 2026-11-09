import SwiftUI

/// The overlay peek is a separate visual surface, never a second split-view
/// column. It is a side panel with the surface of the Project Insights panel
/// (`glassPanel`, `GlassPanelMetrics.sidePanelCornerRadius`), mirrored on the
/// leading side: it starts below the toolbar and keeps the same inset from
/// the window content.
struct SidebarOverlayPanel: View {
    let width: CGFloat
    let chromeHidden: Bool
    let presentation: SidebarPresentationState
    let isInteractive: Bool
    let onResize: (CGFloat) -> Void
    let onResizeStateChanged: (Bool) -> Void

    var body: some View {
        SidebarContent(
            presentation: presentation,
            isInteractive: isInteractive,
            paintsFallbackFooterBackground: false,
            forcesScrollEdgeEffects: true
        )
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // The rows scroll inside the panel's corners, not over its stroke.
        .clipShape(RoundedRectangle(cornerRadius: GlassPanelMetrics.sidePanelCornerRadius, style: .continuous))
        .glassPanel(cornerRadius: GlassPanelMetrics.sidePanelCornerRadius)
        .overlay(alignment: .trailing) {
            ResizeDragBand(
                axis: .horizontal,
                valueAtDragStart: { width },
                resizedValue: { start, delta in
                    SidebarOverlayMetrics.resizedWidth(start: start, delta: delta)
                },
                onResize: onResize,
                onResizeStateChanged: onResizeStateChanged
            )
            .frame(width: SplitDividerMetrics.bandThickness)
        }
        .padding(GlassPanelMetrics.sidePanelInset)
        // With the title bar hidden, SwiftUI keeps the titlebar's safe area.
        // Ignore it, so the inset counts from the window top, as the detail
        // column (and the Project Insights panel in it) does.
        .ignoresSafeArea(chromeHidden ? .container : [], edges: .top)
    }
}

/// Pure decisions at the AppKit/SwiftUI boundary. Keeping these outside
/// `MainWindow` lets interaction regressions be exercised without synthesizing
/// system pointer events, which macOS gates behind Accessibility permission.
@MainActor
enum SidebarPeekInteraction {
    struct LaunchResolution: Equatable {
        let columnVisible: Bool
        let modelVisible: Bool?
    }

    struct RetentionContext {
        let appIsActive: Bool
        let windowIsVisible: Bool
        let windowIsMiniaturized: Bool
        let windowIsKey: Bool
        let peekEnabled: Bool
        let configuredStyle: SidebarPeekStyle
        let menuTrackingDepth: Int
        let pressedMouseButtons: Int
        let pointerIsRetained: Bool
    }

    static func launchResolution(nativeVisible: Bool, modelVisible: Bool) -> LaunchResolution {
        LaunchResolution(
            columnVisible: nativeVisible,
            modelVisible: nativeVisible == modelVisible ? nil : nativeVisible
        )
    }

    static func shouldBeginHover(
        style: SidebarPeekStyle,
        pointX: CGFloat,
        previousX: CGFloat?
    ) -> Bool {
        switch style {
        case .resizeTerminal:
            pointX <= SidebarOverlayMetrics.hoverActivationWidth
        case .overlayTerminal:
            SidebarOverlayMetrics.shouldBeginHover(pointX: pointX, previousX: previousX)
        }
    }

    static func shouldPromoteOverlay(activeStyle: SidebarPeekStyle?, columnVisible: Bool) -> Bool {
        activeStyle == .overlayTerminal && columnVisible
    }

    static func shouldRetainOverlay(_ context: RetentionContext) -> Bool {
        let interactionOwnsPointer = context.menuTrackingDepth > 0
            || (context.pressedMouseButtons & 1) != 0
        return context.appIsActive
            && context.windowIsVisible
            && !context.windowIsMiniaturized
            && context.peekEnabled
            && context.configuredStyle == .overlayTerminal
            && (interactionOwnsPointer || (context.windowIsKey && context.pointerIsRetained))
    }

    /// The pointer x past which a peek of `style` ends. The overlay panel
    /// sits `GlassPanelMetrics.sidePanelInset` in from the leading edge, so
    /// its exit edge moves with it: both styles keep `hoverExitPadding`
    /// past the edge that the user sees.
    static func exitEdge(style: SidebarPeekStyle, sidebarWidth: CGFloat) -> CGFloat {
        switch style {
        case .resizeTerminal:
            sidebarWidth + SidebarOverlayMetrics.hoverExitPadding
        case .overlayTerminal:
            SidebarOverlayMetrics.exitEdge(sidebarWidth: sidebarWidth)
        }
    }

    static func shouldCollapseAfterResize(lastHoverX: CGFloat?, sidebarWidth: CGFloat) -> Bool {
        guard let lastHoverX else { return false }
        return lastHoverX > SidebarOverlayMetrics.exitEdge(sidebarWidth: sidebarWidth)
    }
}

/// Geometry shared by the overlay panel and its hover rules.
@MainActor
enum SidebarOverlayMetrics {
    /// The strip at the leading edge that opens a peek by itself. Both trigger
    /// widths stay inside the terminal's 12-point `window-padding-x`
    /// (`MactermConfig.defaultsBody`), so no pointer over text can open a peek:
    /// #447 was the overlay opening while the pointer travelled leftward to
    /// select the first characters of a line, because the approach corridor
    /// reached 64 points in — four columns past the padding.
    static let hoverActivationWidth: CGFloat = 6
    static let hoverApproachWidth: CGFloat = 12
    static let fastExitRecoveryWidth: CGFloat = 128
    static let hoverExitPadding: CGFloat = 8
    static let outsideAcquisitionDepth: CGFloat = 128
    static let outsideVerticalTolerance: CGFloat = 16

    /// A stationary pointer still has to reach the exact edge zone. A pointer
    /// moving toward the edge gets a slightly wider capture corridor so a
    /// pointer decelerating into the strip cannot land just past it. The
    /// corridor ends inside the terminal's leading padding, never over text.
    static func shouldBeginHover(pointX: CGFloat, previousX: CGFloat?) -> Bool {
        if pointX <= hoverActivationWidth { return true }
        guard let previousX else { return false }
        guard pointX <= hoverApproachWidth else { return false }
        return pointX < previousX
    }

    /// Last-resort recovery when the pointer crosses the left edge between two
    /// hover samples. This is used only for overlay mode and only when movement
    /// was toward the sidebar; spatial outside-window tracking retracts it if
    /// the user did not intend to come back onto the panel.
    static func shouldRecoverFastExit(lastX: CGFloat?, wasApproaching: Bool) -> Bool {
        guard wasApproaching, let lastX else { return false }
        return lastX <= fastExitRecoveryWidth
    }

    /// Global retention region used after SwiftUI hover delivery ends at the
    /// window boundary. The overlay remains open while the pointer is still
    /// beside or over the sidebar, including a forgiving gutter outside the
    /// leading window edge. There is no time-based dismissal inside this area.
    static func retainsOutsidePointer(
        _ pointer: CGPoint,
        windowFrame: CGRect,
        sidebarWidth: CGFloat
    ) -> Bool {
        let minX = windowFrame.minX - outsideAcquisitionDepth
        let maxX = min(windowFrame.minX + exitEdge(sidebarWidth: sidebarWidth), windowFrame.maxX)
        let minY = windowFrame.minY - outsideVerticalTolerance
        let maxY = windowFrame.maxY + outsideVerticalTolerance
        return (minX ... maxX).contains(pointer.x) && (minY ... maxY).contains(pointer.y)
    }

    /// `hoverExitPadding` past the panel's trailing edge, from the window's
    /// leading edge.
    static func exitEdge(sidebarWidth: CGFloat) -> CGFloat {
        GlassPanelMetrics.sidePanelInset + sidebarWidth + hoverExitPadding
    }

    static func resizedWidth(start: CGFloat, delta: CGFloat) -> CGFloat {
        let range = Preferences.sidebarWidthRange
        return min(max(start + delta, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
    }
}

/// Keeps the user's last width authoritative while a native split-view column
/// animates open. SwiftUI reports intermediate/stale native widths during that
/// animation; those must not overwrite a width just dragged on the overlay.
struct SidebarWidthHandoff {
    private(set) var width: CGFloat
    private(set) var pendingNativeWidth: CGFloat?

    mutating func overlayResized(to width: CGFloat) -> CGFloat {
        pendingNativeWidth = nil
        self.width = width
        return width
    }

    /// Take the width that the window saved, when its restore sets it.
    ///
    /// `width` starts at the app-wide launch width, and only native
    /// measurements and overlay drags change it after that. A window that is
    /// restored with its sidebar hidden is never measured, so showing it or
    /// peeking used the width of another window (#552). Returns nil when
    /// nothing changed. A pending handoff target stays as it is.
    mutating func adoptStoredWidth(_ width: CGFloat) -> CGFloat? {
        guard abs(width - self.width) >= 0.5 else { return nil }
        self.width = width
        return width
    }

    mutating func nativeMeasured(_ width: CGFloat) -> CGFloat? {
        if let pendingNativeWidth {
            guard abs(width - pendingNativeWidth) < 0.5 else { return nil }
            self.pendingNativeWidth = nil
        }
        self.width = width
        return width
    }

    mutating func beginNativeHandoff() -> CGFloat {
        let target = pendingNativeWidth ?? width
        pendingNativeWidth = target
        return target
    }

    /// Stop expecting a native measurement to confirm the pending target.
    ///
    /// A handoff that was never applied — or that AppKit clamped short of the
    /// target, which a narrow window does — leaves a value no measurement can
    /// ever match, and `nativeMeasured` would then discard every native width
    /// for the rest of the session. Disarming is always safe: the pending
    /// target only ever holds the current `width`.
    mutating func endNativeHandoff() {
        pendingNativeWidth = nil
    }
}
