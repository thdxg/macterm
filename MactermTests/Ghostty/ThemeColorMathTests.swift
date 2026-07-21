import AppKit
@testable import Macterm
import Testing

struct ThemeColorMathTests {
    @Test
    func contrastRatioUsesExpectedExtremes() {
        #expect(NSColor.white.contrastRatio(with: .black) > 20)
        #expect(NSColor.white.contrastRatio(with: .white) == 1)
        #expect(NSColor.black.contrastRatio(with: .black) == 1)
    }

    @Test
    func visualEqualityUsesTheRequestedTolerance() {
        let reference = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        let near = NSColor(srgbRed: 0.201, green: 0.301, blue: 0.401, alpha: 1)
        let far = NSColor(srgbRed: 0.25, green: 0.3, blue: 0.4, alpha: 1)

        #expect(reference.isVisuallyEqual(to: near))
        #expect(!reference.isVisuallyEqual(to: far))
    }

    @Test
    func semanticForegroundUsesContrastRatherThanRawBrightness() {
        let vividRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let vividMagenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let navy = NSColor(srgbRed: 0.02, green: 0.04, blue: 0.18, alpha: 1)

        #expect(vividRed.prefersDarkForeground)
        #expect(vividMagenta.prefersDarkForeground)
        #expect(!navy.prefersDarkForeground)
    }
}
