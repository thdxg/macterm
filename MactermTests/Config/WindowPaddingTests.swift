@testable import Macterm
import Testing

struct WindowPaddingTests {
    @Test
    func one_number_sets_the_left_padding() {
        #expect(WindowPadding.parse("10").left == 10)
        #expect(WindowPadding.parse(" 4 ").left == 4)
    }

    @Test
    func a_pair_takes_the_left_value() {
        #expect(WindowPadding.parse("12,4").left == 12)
        #expect(WindowPadding.parse("3 , 9").left == 3)
    }

    @Test
    func an_absent_or_bad_value_is_ghosttys_default() {
        #expect(WindowPadding.parse(nil) == .default)
        #expect(WindowPadding.parse("") == .default)
        #expect(WindowPadding.parse("wide") == .default)
        #expect(WindowPadding.parse("-2") == .default)
        #expect(WindowPadding.default.left == 2)
    }

    @Test
    func the_last_value_in_the_config_wins() {
        let text = "window-padding-x = 8\nfont-size = 14\nwindow-padding-x = 20,6\n"
        #expect(WindowPadding.resolve(userConfigText: text).left == 20)
        #expect(WindowPadding.resolve(userConfigText: nil) == .default)
    }
}
