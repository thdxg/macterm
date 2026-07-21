import AppKit
@testable import Macterm
import Testing

struct TerminalBackgroundOverrideTests {
    @Test
    func parsesAndCanonicalizesHexColors() throws {
        let color = try #require(TerminalBackgroundColor(hex: "  1a2B3c  "))

        #expect(color == TerminalBackgroundColor(red: 0x1A, green: 0x2B, blue: 0x3C))
        #expect(color.hex == "#1A2B3C")
    }

    @Test
    func rejectsMalformedHexColors() {
        #expect(TerminalBackgroundColor(hex: "#12345") == nil)
        #expect(TerminalBackgroundColor(hex: "#GG0000") == nil)
        #expect(TerminalBackgroundColor(hex: "#11223344") == nil)
    }

    @Test
    func convertsDisplayColorsThroughSRGB() throws {
        let source = NSColor(displayP3Red: 0.25, green: 0.5, blue: 0.75, alpha: 0.2)
        let value = try #require(TerminalBackgroundColor(nsColor: source))
        let expected = try #require(source.usingColorSpace(.sRGB))

        #expect(abs(value.nsColor.redComponent - expected.redComponent) <= 0.5 / 255)
        #expect(abs(value.nsColor.greenComponent - expected.greenComponent) <= 0.5 / 255)
        #expect(abs(value.nsColor.blueComponent - expected.blueComponent) <= 0.5 / 255)
        #expect(value.nsColor.alphaComponent == 1)
    }

    @Test
    func emitsBackgroundAndContrastingForegroundOnlyForCustomMode() {
        let dark = TerminalBackgroundColor(red: 0x12, green: 0x34, blue: 0x56)
        let vivid = TerminalBackgroundColor(red: 0xFF, green: 0x00, blue: 0x66)

        #expect(TerminalBackgroundOverride.configLines(source: .ghosttyConfig, color: dark).isEmpty)
        #expect(TerminalBackgroundOverride.configLines(source: .custom, color: dark) == [
            "background = #123456",
            "foreground = #FFFFFF",
        ])
        #expect(TerminalBackgroundOverride.configLines(source: .custom, color: vivid) == [
            "background = #FF0066",
            "foreground = #000000",
        ])
    }
}
