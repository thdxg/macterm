@testable import Macterm
import Testing

/// The two forms ghostty's own parser accepts for
/// `mouse-scroll-multiplier`, read from raw config text.
struct MouseScrollMultiplierTests {
    @Test
    func a_bare_number_sets_both_halves() {
        let value = MouseScrollMultiplier.parse("2.5")
        #expect(value.precision == 2.5)
        #expect(value.discrete == 2.5)
    }

    @Test
    func named_fields_set_one_half_each_and_default_the_rest() {
        #expect(MouseScrollMultiplier.parse("precision:1.5").precision == 1.5)
        #expect(MouseScrollMultiplier.parse("precision:1.5").discrete == MouseScrollMultiplier.default.discrete)
        let both = MouseScrollMultiplier.parse(" precision:2 , discrete:4 ")
        #expect(both.precision == 2)
        #expect(both.discrete == 4)
    }

    @Test
    func an_unusable_value_falls_back_to_ghosttys_defaults() {
        #expect(MouseScrollMultiplier.parse(nil) == .default)
        #expect(MouseScrollMultiplier.parse("") == .default)
        #expect(MouseScrollMultiplier.parse("fast") == .default)
        #expect(MouseScrollMultiplier.parse("sideways:3") == .default)
        #expect(MouseScrollMultiplier.default.precision == 1)
        #expect(MouseScrollMultiplier.default.discrete == 3)
    }

    @Test
    func it_reads_the_last_assignment_in_the_config_text() {
        let text = """
        mouse-scroll-multiplier = 2
        font-size = 13
        mouse-scroll-multiplier = precision:0.5,discrete:6
        """
        let value = MouseScrollMultiplier.resolve(userConfigText: text)
        #expect(value.precision == 0.5)
        #expect(value.discrete == 6)
    }
}
