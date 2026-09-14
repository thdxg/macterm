@testable import Macterm
import Testing

/// `MouseScrollMultiplier.resolve` reads ghostty's `mouse-scroll-multiplier`
/// out of the raw config text with ghostty's own grammar (the cases below
/// mirror `Config.MouseScrollMultiplier`'s `parse` test upstream) on top of
/// libghostty's line semantics: last wins, empty resets.
struct MouseScrollMultiplierTests {
    private func resolve(_ text: String?) -> MouseScrollMultiplier {
        MouseScrollMultiplier.resolve(userConfigText: text)
    }

    @Test
    func anUnsetKeyIsMactermsDefaultNotGhosttys() {
        // Ghostty's own default is precision:1,discrete:3; Macterm pins 1/1 in
        // its defaults layer, and the resolver's fallback must be that pin.
        #expect(resolve(nil) == .mactermDefault)
        #expect(resolve("font-size = 16") == .mactermDefault)
        #expect(MouseScrollMultiplier.mactermDefault == MouseScrollMultiplier(precision: 1, discrete: 1))
    }

    @Test
    func aBareNumberSetsBothDeviceClasses() {
        #expect(resolve("mouse-scroll-multiplier = 3") == MouseScrollMultiplier(precision: 3, discrete: 3))
        #expect(resolve("mouse-scroll-multiplier = 0.5") == MouseScrollMultiplier(precision: 0.5, discrete: 0.5))
    }

    @Test
    func aPartialFormKeepsTheOtherField() {
        #expect(resolve("mouse-scroll-multiplier = precision:2") == MouseScrollMultiplier(precision: 2, discrete: 1))
        #expect(resolve("mouse-scroll-multiplier = discrete:5") == MouseScrollMultiplier(precision: 1, discrete: 5))
    }

    @Test
    func bothFieldsInEitherOrder() {
        #expect(
            resolve("mouse-scroll-multiplier = precision:3,discrete:7")
                == MouseScrollMultiplier(precision: 3, discrete: 7)
        )
        #expect(
            resolve("mouse-scroll-multiplier = discrete:8, precision:6")
                == MouseScrollMultiplier(precision: 6, discrete: 8)
        )
    }

    /// Ghostty processes lines in order and a partial form starts from the
    /// value the key already has, so a later `discrete:` line builds on an
    /// earlier bare number rather than on the default.
    @Test
    func laterLinesBuildOnEarlierOnesAndAnEmptyValueResets() {
        let text = """
        mouse-scroll-multiplier = 2
        mouse-scroll-multiplier = discrete:4
        """
        #expect(resolve(text) == MouseScrollMultiplier(precision: 2, discrete: 4))

        let reset = """
        mouse-scroll-multiplier = 2
        mouse-scroll-multiplier =
        """
        #expect(resolve(reset) == .mactermDefault)
    }

    /// A line ghostty would refuse (and log) leaves the previous value alone.
    @Test
    func anInvalidLineIsDroppedNotDefaulted() {
        #expect(resolve("mouse-scroll-multiplier = foo:1") == .mactermDefault)
        #expect(resolve("mouse-scroll-multiplier = precision:bar") == .mactermDefault)
        #expect(resolve("mouse-scroll-multiplier = precision:1,discrete:3,foo:5") == .mactermDefault)
        #expect(resolve("mouse-scroll-multiplier = precision:1,,discrete:3") == .mactermDefault)
        let text = """
        mouse-scroll-multiplier = 2
        mouse-scroll-multiplier = nonsense
        """
        #expect(resolve(text) == MouseScrollMultiplier(precision: 2, discrete: 2))
    }

    @Test
    func valuesAreClampedToGhosttysRange() {
        #expect(resolve("mouse-scroll-multiplier = 0") == MouseScrollMultiplier(precision: 0.01, discrete: 0.01))
        #expect(resolve("mouse-scroll-multiplier = 1e9") == MouseScrollMultiplier(precision: 10000, discrete: 10000))
        #expect(resolve("mouse-scroll-multiplier = -2") == MouseScrollMultiplier(precision: 0.01, discrete: 0.01))
    }

    @Test
    func picksTheFieldByWhetherTheEventIsPrecise() {
        let m = MouseScrollMultiplier(precision: 0.5, discrete: 4)
        #expect(m.value(precise: true) == 0.5)
        #expect(m.value(precise: false) == 4)
    }
}
