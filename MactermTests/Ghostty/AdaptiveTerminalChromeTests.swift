import AppKit
@testable import Macterm
import Testing

/// The pure rules of `AdaptiveTerminalChrome`; the sampling loop itself needs
/// live surfaces and is exercised in the app.
@MainActor
struct AdaptiveTerminalChromeTests {
    private let paint = CGRect(x: 4, y: 6, width: 300, height: 200)
    /// A TUI background painted at the window opacity (`background-opacity-cells`).
    private let translucent = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.14, alpha: 0.8)
    private let opaque = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.14, alpha: 1)

    @Test
    func a_translucently_painted_pane_cuts_the_tint_under_its_paint() {
        #expect(
            AdaptiveTerminalChrome.tintHole(color: translucent, paintedRect: paint, hiddenInLayout: false)
                == paint
        )
    }

    @Test
    func an_opaquely_painted_pane_gets_a_fill_instead_of_a_hole() {
        #expect(AdaptiveTerminalChrome.paneFill(opaque) != nil)
        #expect(AdaptiveTerminalChrome.tintHole(color: opaque, paintedRect: paint, hiddenInLayout: false) == nil)
    }

    @Test
    func no_color_or_no_sampled_paint_cuts_nothing() {
        #expect(AdaptiveTerminalChrome.tintHole(color: nil, paintedRect: paint, hiddenInLayout: false) == nil)
        #expect(
            AdaptiveTerminalChrome.tintHole(color: translucent, paintedRect: nil, hiddenInLayout: false) == nil
        )
    }

    /// A pane zoomed away stays mounted, invisible, with its frame and its
    /// sampled paint; the hole it was cutting must go with its visibility, or
    /// the zoomed pane shows the bare material through the rectangle it left.
    @Test
    func a_pane_hidden_behind_a_zoomed_sibling_cuts_nothing() {
        #expect(
            AdaptiveTerminalChrome.tintHole(color: translucent, paintedRect: paint, hiddenInLayout: true) == nil
        )
    }
}
