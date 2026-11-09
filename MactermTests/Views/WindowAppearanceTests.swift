import AppKit
@testable import Macterm
import Testing

@MainActor
struct WindowAppearanceTests {
    private let dark = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    private let light = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)

    /// Where the titlebar shows the terminal, the title takes the scheme of
    /// the terminal background, as Ghostty.app's transparent titlebar does.
    @Test
    func theTitleFollowsTheTerminalBackground() {
        #expect(WindowAppearance.titleAppearanceName(background: dark, titlebarBackgroundShown: false) == .darkAqua)
        #expect(WindowAppearance.titleAppearanceName(background: light, titlebarBackgroundShown: false) == .aqua)
    }

    /// Where AppKit paints its own titlebar background, the title is on
    /// chrome and keeps the window's appearance.
    @Test
    func theTitleOnAppKitsTitlebarKeepsTheWindowAppearance() {
        #expect(WindowAppearance.titleAppearanceName(background: dark, titlebarBackgroundShown: true) == nil)
        #expect(WindowAppearance.titleAppearanceName(background: light, titlebarBackgroundShown: true) == nil)
    }
}
