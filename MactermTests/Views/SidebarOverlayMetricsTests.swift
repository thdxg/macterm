import CoreGraphics
@testable import Macterm
import Testing

@MainActor
struct SidebarOverlayMetricsTests {
    @Test
    func inset_corner_radius_stays_concentric_with_window() {
        #expect(SidebarOverlayMetrics.cornerRadius(windowCornerRadius: 24, inset: 4) == 20)
        #expect(SidebarOverlayMetrics.cornerRadius(windowCornerRadius: 8, inset: 4) == 4)
    }

    @Test
    func missing_or_small_window_radius_never_produces_negative_radius() {
        #expect(SidebarOverlayMetrics.cornerRadius(windowCornerRadius: nil, inset: 4) == 0)
        #expect(SidebarOverlayMetrics.cornerRadius(windowCornerRadius: 2, inset: 4) == 0)
    }

    @Test
    func hover_trigger_captures_edge_entries_and_leftward_approach() {
        #expect(SidebarOverlayMetrics.shouldBeginHover(pointX: 4, previousX: nil))
        #expect(SidebarOverlayMetrics.shouldBeginHover(pointX: 4, previousX: 3))
        #expect(SidebarOverlayMetrics.shouldBeginHover(pointX: 10, previousX: 20))

        #expect(!SidebarOverlayMetrics.shouldBeginHover(pointX: 10, previousX: nil))
        #expect(!SidebarOverlayMetrics.shouldBeginHover(pointX: 10, previousX: 8))
        #expect(!SidebarOverlayMetrics.shouldBeginHover(pointX: 48, previousX: 90))
    }

    /// #447: the overlay opened while the pointer travelled leftward to select
    /// the first characters of a line. Both trigger widths must stay inside the
    /// terminal's leading padding so no pointer over text can open a peek.
    @Test
    func hover_trigger_stays_inside_the_terminal_padding() {
        let padding: CGFloat = 16
        #expect(SidebarOverlayMetrics.hoverActivationWidth < padding)
        #expect(SidebarOverlayMetrics.hoverApproachWidth < padding)
        #expect(!SidebarOverlayMetrics.shouldBeginHover(pointX: padding, previousX: 200))
    }

    @Test
    func fast_exit_recovery_requires_leftward_motion_near_the_sidebar() {
        #expect(SidebarOverlayMetrics.shouldRecoverFastExit(lastX: 100, wasApproaching: true))
        #expect(!SidebarOverlayMetrics.shouldRecoverFastExit(lastX: 160, wasApproaching: true))
        #expect(!SidebarOverlayMetrics.shouldRecoverFastExit(lastX: 100, wasApproaching: false))
        #expect(!SidebarOverlayMetrics.shouldRecoverFastExit(lastX: nil, wasApproaching: true))
    }

    @Test
    func outside_pointer_is_retained_only_while_spatially_beside_sidebar() {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 700)

        #expect(SidebarOverlayMetrics.retainsOutsidePointer(
            CGPoint(x: 80, y: 400),
            windowFrame: window,
            sidebarWidth: 200
        ))
        #expect(SidebarOverlayMetrics.retainsOutsidePointer(
            CGPoint(x: 250, y: 400),
            windowFrame: window,
            sidebarWidth: 200
        ))

        #expect(!SidebarOverlayMetrics.retainsOutsidePointer(
            CGPoint(x: -40, y: 400),
            windowFrame: window,
            sidebarWidth: 200
        ))
        #expect(!SidebarOverlayMetrics.retainsOutsidePointer(
            CGPoint(x: 320, y: 400),
            windowFrame: window,
            sidebarWidth: 200
        ))
        #expect(!SidebarOverlayMetrics.retainsOutsidePointer(
            CGPoint(x: 120, y: 850),
            windowFrame: window,
            sidebarWidth: 200
        ))
    }

    @Test
    func resize_width_uses_native_sidebar_bounds() {
        let range = Preferences.sidebarWidthRange
        #expect(SidebarOverlayMetrics.resizedWidth(start: 180, delta: 25) == 205)
        #expect(SidebarOverlayMetrics.resizedWidth(
            start: 180,
            delta: CGFloat(range.lowerBound) - 180 - 40
        ) == CGFloat(range.lowerBound))
        #expect(SidebarOverlayMetrics.resizedWidth(
            start: 180,
            delta: CGFloat(range.upperBound) - 180 + 40
        ) == CGFloat(range.upperBound))
    }

    @Test
    func titlebar_inset_uses_the_non_obscured_window_layout_rect() {
        let contentFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        #expect(SidebarOverlayMetrics.topObscuredInset(
            contentFrameInWindow: contentFrame,
            contentLayoutRect: CGRect(x: 0, y: 0, width: 1000, height: 748)
        ) == 52)
        #expect(SidebarOverlayMetrics.topObscuredInset(
            contentFrameInWindow: contentFrame,
            contentLayoutRect: CGRect(x: 0, y: 0, width: 1000, height: 800)
        ) == 0)
    }

    @Test
    func overlay_top_bar_and_shared_spacing_sum_to_the_window_inset() {
        let inset: CGFloat = 52
        let bar = SidebarLayoutMetrics.overlayTopBarHeight(windowTopInset: inset)

        #expect(bar == 40)
        #expect(bar + SidebarLayoutMetrics.topContentMargin + SidebarLayoutMetrics.idlePinDropHeight == inset)
        #expect(SidebarLayoutMetrics.overlayTopBlurHeight(topBarHeight: bar) == inset)
    }

    @Test
    func native_handoff_ignores_stale_animation_widths_until_target_arrives() {
        var handoff = SidebarWidthHandoff(width: 180)
        #expect(handoff.overlayResized(to: 260) == 260)
        #expect(handoff.beginNativeHandoff() == 260)

        #expect(handoff.nativeMeasured(180) == nil)
        #expect(handoff.width == 260)
        #expect(handoff.pendingNativeWidth == 260)

        #expect(handoff.nativeMeasured(260) == 260)
        #expect(handoff.pendingNativeWidth == nil)
    }

    @Test
    func cancelled_handoff_survives_until_next_native_show_or_new_overlay_drag() {
        var handoff = SidebarWidthHandoff(width: 240)
        #expect(handoff.beginNativeHandoff() == 240)
        #expect(handoff.nativeMeasured(170) == nil)

        // A later show reuses the still-authoritative target.
        #expect(handoff.beginNativeHandoff() == 240)

        // An explicit new overlay drag supersedes it.
        #expect(handoff.overlayResized(to: 300) == 300)
        #expect(handoff.pendingNativeWidth == nil)
    }

    @Test
    func an_unreachable_target_is_disarmed_instead_of_discarding_every_width() {
        var handoff = SidebarWidthHandoff(width: 400)
        #expect(handoff.beginNativeHandoff() == 400)

        // A narrow window clamps the divider short of the target, so no
        // measurement will ever match it.
        #expect(handoff.nativeMeasured(300) == nil)

        handoff.endNativeHandoff()
        #expect(handoff.pendingNativeWidth == nil)
        #expect(handoff.nativeMeasured(300) == 300)
        #expect(handoff.width == 300)
    }
}
