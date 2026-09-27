import CoreGraphics
@testable import Macterm
import Testing

struct NativeDesktopWidgetsTests {
    private let host: pid_t = 675
    private let screenHeight: CGFloat = 1692

    private func window(
        pid: pid_t? = nil,
        layer: Int = NativeDesktopWidgets.widgetLevel,
        alpha: Double = 1,
        _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid ?? host,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height],
        ]
    }

    private func frames(_ windows: [[String: Any]]) -> [CGRect] {
        NativeDesktopWidgets.widgetFrames(in: windows, primaryScreenHeight: screenHeight) { $0 == host }
    }

    /// The window list of a real desktop (macOS 27): a medium weather widget,
    /// an extra-large-portrait calendar below it, and the invisible window
    /// Notification Center left behind — which was being read as a widget,
    /// blocking the cells it covered and dragging Macterm's widgets onto its
    /// lattice.
    @Test
    func only_the_real_widgets_are_read_from_a_real_desktop() {
        let found = frames([
            window(18, 55, 360, 180),
            window(18, 235, 360, 720),
            window(layer: NativeDesktopWidgets.widgetLevel - 1, alpha: 0, -44, 274, 464, 824),
        ])
        #expect(found == [
            CGRect(x: 26, y: 1692 - 55 - 180 + 8, width: 344, height: 164),
            CGRect(x: 26, y: 1692 - 235 - 720 + 8, width: 344, height: 704),
        ])
    }

    @Test
    func a_transparent_window_is_not_a_widget() {
        #expect(frames([window(alpha: 0, 18, 55, 360, 180)]).isEmpty)
    }

    /// A widget window is whole cells each way — 180pt apiece, shadow
    /// insets included — so a window that isn't is something else.
    @Test
    func a_window_that_is_not_whole_cells_is_not_a_widget() {
        #expect(frames([window(18, 55, 464, 180)]).isEmpty)
        #expect(frames([window(18, 55, 360, 824)]).isEmpty)
        #expect(frames([window(18, 55, 100, 100)]).isEmpty)
    }

    @Test
    func another_app_or_a_window_outside_the_desktop_band_is_not_a_widget() {
        #expect(frames([window(pid: 1, 18, 55, 360, 180)]).isEmpty)
        #expect(frames([window(layer: 0, 18, 55, 360, 180)]).isEmpty)
        #expect(frames([window(layer: NativeDesktopWidgets.desktopLevels.lowerBound - 1, 18, 55, 360, 180)]).isEmpty)
        // Anywhere in the band counts, not only the level measured today.
        #expect(frames([window(layer: NativeDesktopWidgets.desktopLevels.lowerBound, 18, 55, 360, 180)]).count == 1)
    }
}
