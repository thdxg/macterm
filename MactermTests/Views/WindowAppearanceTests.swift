import AppKit
@testable import Macterm
import Testing

@MainActor
struct WindowAppearanceTests {
    /// The title is drawn over the terminal, so its scheme follows the
    /// terminal background, as Ghostty.app's transparent titlebar does. It
    /// never reads `window-theme`: a light chrome on a dark terminal must
    /// still draw a light title.
    @Test
    func theTitleFollowsTheTerminalBackground() {
        let dark = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        let light = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        #expect(WindowAppearance.titleAppearanceName(background: dark) == .darkAqua)
        #expect(WindowAppearance.titleAppearanceName(background: light) == .aqua)
    }
}
