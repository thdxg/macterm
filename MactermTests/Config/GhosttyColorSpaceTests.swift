import AppKit
@testable import Macterm
import Testing

struct GhosttyColorSpaceTests {
    @Test
    func defaultsToSRGBWhenTheUserNeverSaysOtherwise() {
        #expect(GhosttyColorSpace.resolve(userConfigText: nil) == .sRGB)
        #expect(GhosttyColorSpace.resolve(userConfigText: "font-size = 16") == .sRGB)
        #expect(GhosttyColorSpace.resolve(userConfigText: "window-colorspace = srgb") == .sRGB)
    }

    @Test
    func readsDisplayP3AndTakesTheLastMention() {
        #expect(GhosttyColorSpace.resolve(userConfigText: "window-colorspace = display-p3") == .displayP3)
        // libghostty applies last-wins, so a later line must win here too.
        let text = """
        window-colorspace = display-p3
        window-colorspace = srgb
        """
        #expect(GhosttyColorSpace.resolve(userConfigText: text) == .sRGB)
    }

    @Test
    func anUnrecognizedValueIsSRGBRatherThanAGuess() {
        #expect(GhosttyColorSpace.resolve(userConfigText: "window-colorspace = rec2020") == .sRGB)
    }

    /// The whole point of resolving it: a color sampled from a Display P3
    /// surface and labelled sRGB lands a couple of counts off, which is visible
    /// where a pane's own paint meets the chrome tint matching it.
    @Test
    func labellingP3NumbersAsSRGBShiftsTheColor() throws {
        let painted = AdaptiveTerminalBackgroundDetector.Match(
            red: 40, green: 30, blue: 60, alpha: 221, coverage: 1
        )
        let asP3 = try #require(painted.color(in: .displayP3).usingColorSpace(.sRGB))
        let asSRGB = try #require(painted.color(in: .sRGB).usingColorSpace(.sRGB))
        #expect(asP3.distance(to: asSRGB) > 2.0 / 255)
    }
}
