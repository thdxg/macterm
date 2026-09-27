import CoreGraphics
@testable import Macterm
import Testing

struct DesktopWidgetResizeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 344, height: 164)
    private let minSize = CGSize(width: 164, height: 164)

    @Test
    func the_band_just_inside_each_edge_grabs_that_edge() {
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 3, y: 80), in: bounds) == [.left])
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 340, y: 80), in: bounds) == [.right])
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 170, y: 161), in: bounds) == [.top])
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 170, y: 2), in: bounds) == [.bottom])
    }

    /// A corner is the handle people reach for, so it reaches further along
    /// its edges than the band is deep.
    @Test
    func near_a_corner_the_band_grabs_both_edges() {
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 15, y: 161), in: bounds) == [.top, .left])
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 341, y: 15), in: bounds) == [.bottom, .right])
    }

    /// The inner part of the margin moves the widget, and the terminal
    /// (inset by the 11pt margin) never loses a point to the handle.
    @Test
    func the_rest_of_the_margin_and_the_terminal_grab_nothing() {
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 9, y: 80), in: bounds).isEmpty)
        #expect(DesktopWidgetResize.edges(at: CGPoint(x: 170, y: 80), in: bounds).isEmpty)
        #expect(DesktopWidgetResize.band < DesktopWidgetMetrics.contentMargin)
    }

    @Test
    func dragging_an_edge_moves_only_that_edge() {
        let start = CGRect(x: 100, y: 100, width: 344, height: 164)
        let wider = DesktopWidgetResize.frame(from: start, edges: [.right], by: CGSize(width: 50, height: 9), minSize: minSize)
        #expect(wider == CGRect(x: 100, y: 100, width: 394, height: 164))
        let fromLeft = DesktopWidgetResize.frame(from: start, edges: [.left], by: CGSize(width: -40, height: 0), minSize: minSize)
        #expect(fromLeft == CGRect(x: 60, y: 100, width: 384, height: 164))
        // Up is +y: dragging the top up grows the widget; the bottom stays.
        let taller = DesktopWidgetResize.frame(from: start, edges: [.top], by: CGSize(width: 0, height: 30), minSize: minSize)
        #expect(taller == CGRect(x: 100, y: 100, width: 344, height: 194))
        let fromBottom = DesktopWidgetResize.frame(from: start, edges: [.bottom], by: CGSize(width: 0, height: -30), minSize: minSize)
        #expect(fromBottom == CGRect(x: 100, y: 70, width: 344, height: 194))
    }

    @Test
    func a_resize_never_goes_below_one_cell_and_keeps_the_opposite_edge() {
        let start = CGRect(x: 100, y: 100, width: 344, height: 164)
        let squeezed = DesktopWidgetResize.frame(
            from: start,
            edges: [.top, .left],
            by: CGSize(width: 500, height: -500),
            minSize: minSize
        )
        #expect(squeezed.size == minSize)
        #expect(squeezed.maxX == start.maxX)
        #expect(squeezed.minY == start.minY)
    }
}
