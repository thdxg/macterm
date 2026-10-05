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

    private let frame = CGRect(x: 0, y: 0, width: 320, height: 220)

    private func region(_ color: NSColor?, painted: CGRect? = nil, hidden: Bool = false) -> TerminalPaintRegion? {
        AdaptiveTerminalChrome.paintRegion(
            color: color,
            frame: frame,
            paintedRect: painted ?? paint,
            hiddenInLayout: hidden
        )
    }

    /// The pane's whole frame leaves the window tint, so its unpainted margin
    /// (libghostty's `window-padding`) can be refilled in the pane's own
    /// color — in a split, where the window keeps the configured theme, the
    /// margin used to frame the TUI in that theme. The paint itself stays
    /// uncovered: the cells already carry the color at the window opacity.
    @Test
    func a_translucently_painted_pane_claims_its_frame_and_leaves_its_paint_bare() {
        let region = region(translucent)
        #expect(region?.frame == frame)
        #expect(region?.painted == paint)
        // The pure hue: the backdrop composites it at the window opacity.
        #expect(region?.color.alpha == 1)
    }

    @Test
    func an_opaquely_painted_pane_gets_a_fill_instead_of_a_region() {
        #expect(AdaptiveTerminalChrome.paneFill(opaque) != nil)
        #expect(region(opaque) == nil)
    }

    @Test
    func no_color_or_no_sampled_paint_claims_nothing() {
        #expect(region(nil) == nil)
        #expect(
            AdaptiveTerminalChrome.paintRegion(color: translucent, frame: frame, paintedRect: nil, hiddenInLayout: false)
                == nil
        )
    }

    /// A pane zoomed away stays mounted, invisible, with its frame and its
    /// sampled paint; the hole it was cutting must go with its visibility, or
    /// the zoomed pane shows the bare material through the rectangle it left.
    @Test
    func a_pane_hidden_behind_a_zoomed_sibling_claims_nothing() {
        #expect(region(translucent, hidden: true) == nil)
    }

    /// libghostty reports an OSC 11 color as a bare RGB triple. Under the
    /// user's `background-opacity-cells` the cells carrying it are painted at
    /// the window opacity, so the report is read at that alpha — taken as
    /// opaque, it answered a translucent paint with an opaque pane fill and
    /// no tint hole (Helix 25.07 reports its background on `:theme`).
    @Test
    func a_reported_color_is_painted_at_the_cell_opacity() {
        let alpha = AdaptiveTerminalChrome.reportedPaintAlpha(backgroundOpacityCells: true, windowOpacity: 0.8)
        #expect(alpha == 0.8)
        let reported = opaque.withAlphaComponent(alpha)
        #expect(AdaptiveTerminalChrome.paneFill(reported) == nil)
        #expect(region(reported)?.painted == paint)
    }

    /// Without the flag every explicitly colored cell is opaque, and so is
    /// the report; a window at full opacity paints opaque either way.
    @Test
    func a_reported_color_is_opaque_when_cells_are() {
        #expect(AdaptiveTerminalChrome.reportedPaintAlpha(backgroundOpacityCells: false, windowOpacity: 0.8) == 1)
        #expect(AdaptiveTerminalChrome.reportedPaintAlpha(backgroundOpacityCells: true, windowOpacity: 1) == 1)
        #expect(AdaptiveTerminalChrome.reportedPaintAlpha(backgroundOpacityCells: true, windowOpacity: 1.5) == 1)
    }
}
