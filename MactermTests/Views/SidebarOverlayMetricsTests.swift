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
    func resize_width_uses_native_sidebar_bounds() {
        let range = Preferences.sidebarWidthRange
        #expect(SidebarOverlayMetrics.resizedWidth(start: 180, delta: 25) == 205)
        #expect(SidebarOverlayMetrics.resizedWidth(start: 180, delta: -200) == CGFloat(range.lowerBound))
        #expect(SidebarOverlayMetrics.resizedWidth(start: 180, delta: 200) == CGFloat(range.upperBound))
    }
}
