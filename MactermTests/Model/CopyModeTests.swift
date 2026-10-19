@testable import Macterm
import Testing

struct CopyModeTests {
    // MARK: - Keys

    private static func letter(_ c: String, shift: Bool = false, option: Bool = false) -> CopyModeKey {
        CopyModeKey(
            characters: shift ? c.uppercased() : c,
            charactersIgnoringModifiers: shift ? c.uppercased() : c,
            keyCode: 0,
            option: option,
            shift: shift
        )
    }

    private static func control(_ c: String) -> CopyModeKey {
        CopyModeKey(characters: "\u{1}", charactersIgnoringModifiers: c, keyCode: 0, control: true)
    }

    private static func command(_ c: String) -> CopyModeKey {
        CopyModeKey(characters: c, charactersIgnoringModifiers: c, keyCode: 0, command: true)
    }

    private static func symbol(_ c: String) -> CopyModeKey {
        CopyModeKey(characters: c, charactersIgnoringModifiers: c, keyCode: 0, shift: c == "%")
    }

    private static func named(_ keyCode: UInt16) -> CopyModeKey {
        CopyModeKey(characters: "", charactersIgnoringModifiers: "", keyCode: keyCode)
    }

    private static let escape = named(53)

    private static func resolve(_ keys: [CopyModeKey], state: inout CopyModeState) -> [CopyModeCommand]? {
        var last: [CopyModeCommand]?
        for key in keys {
            last = HelixKeymap.resolve(key, state: &state)
        }
        return last
    }

    // MARK: - Motions

    @Test
    func hjkl_and_arrows_move_in_normal_mode_and_extend_in_select_mode() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("h"), state: &state) == [.binding("move_selection:left")])
        #expect(HelixKeymap.resolve(Self.letter("j"), state: &state) == [.binding("move_selection:down")])
        #expect(HelixKeymap.resolve(Self.letter("k"), state: &state) == [.binding("move_selection:up")])
        #expect(HelixKeymap.resolve(Self.letter("l"), state: &state) == [.binding("move_selection:right")])
        #expect(HelixKeymap.resolve(Self.named(123), state: &state) == [.binding("move_selection:left")])
        #expect(HelixKeymap.resolve(Self.named(126), state: &state) == [.binding("move_selection:up")])

        state.selectMode = true
        #expect(HelixKeymap.resolve(Self.letter("j"), state: &state) == [.binding("extend_selection:down")])
        #expect(HelixKeymap.resolve(Self.named(124), state: &state) == [.binding("extend_selection:right")])
    }

    @Test
    func word_motions_select_the_range_in_normal_mode_and_only_extend_in_select_mode() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("w"), state: &state) == [
            .binding("collapse_selection"), .binding("extend_selection:word_next"),
        ])
        #expect(HelixKeymap.resolve(Self.letter("e"), state: &state) == [
            .binding("collapse_selection"), .binding("extend_selection:word_end"),
        ])
        #expect(HelixKeymap.resolve(Self.letter("b"), state: &state) == [
            .binding("collapse_selection"), .binding("extend_selection:word_prev"),
        ])

        state.selectMode = true
        #expect(HelixKeymap.resolve(Self.letter("w"), state: &state) == [.binding("extend_selection:word_next")])
    }

    @Test
    func x_selects_the_line_in_both_modes() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("x"), state: &state) == [.binding("select_line")])
        state.selectMode = true
        #expect(HelixKeymap.resolve(Self.letter("x"), state: &state) == [.binding("select_line")])
    }

    @Test
    func g_prefix_picks_a_goto_motion() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("g"), state: &state)?.isEmpty == true)
        #expect(state.pending == .prefixG)
        #expect(HelixKeymap.resolve(Self.letter("g"), state: &state) == [.binding("move_selection:top")])
        #expect(state.pending == .none)

        #expect(Self.resolve([Self.letter("g"), Self.letter("e")], state: &state) == [.binding("move_selection:bottom")])
        #expect(Self.resolve([Self.letter("g"), Self.letter("h")], state: &state) == [.binding("move_selection:line_start")])
        #expect(Self.resolve([Self.letter("g"), Self.letter("l")], state: &state) == [.binding("move_selection:line_end")])

        state.selectMode = true
        #expect(Self.resolve([Self.letter("g"), Self.letter("g")], state: &state) == [.binding("extend_selection:top")])
    }

    @Test
    func an_unknown_key_after_g_cancels_the_prefix_and_is_swallowed() {
        var state = CopyModeState()
        #expect(Self.resolve([Self.letter("g"), Self.letter("z")], state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
        // The next key is read on its own again.
        #expect(HelixKeymap.resolve(Self.letter("j"), state: &state) == [.binding("move_selection:down")])
    }

    @Test
    func page_motions_come_from_control_chords_and_named_keys() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.control("u"), state: &state) == [.binding("move_selection:half_page_up")])
        #expect(HelixKeymap.resolve(Self.control("d"), state: &state) == [.binding("move_selection:half_page_down")])
        #expect(HelixKeymap.resolve(Self.control("b"), state: &state) == [.binding("move_selection:page_up")])
        #expect(HelixKeymap.resolve(Self.control("f"), state: &state) == [.binding("move_selection:page_down")])
        #expect(HelixKeymap.resolve(Self.named(116), state: &state) == [.binding("move_selection:page_up")])
        #expect(HelixKeymap.resolve(Self.named(121), state: &state) == [.binding("move_selection:page_down")])
        #expect(HelixKeymap.resolve(Self.named(115), state: &state) == [.binding("move_selection:line_start")])
        #expect(HelixKeymap.resolve(Self.named(119), state: &state) == [.binding("move_selection:line_end")])

        state.selectMode = true
        #expect(HelixKeymap.resolve(Self.control("d"), state: &state) == [.binding("extend_selection:half_page_down")])
    }

    @Test
    func an_unlisted_control_chord_is_swallowed() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.control("c"), state: &state)?.isEmpty == true)
    }

    // MARK: - Counts

    @Test
    func a_count_repeats_the_motion_and_then_resets() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("3"), state: &state)?.isEmpty == true)
        #expect(state.pending == .count(3))
        #expect(HelixKeymap.resolve(Self.letter("j"), state: &state) == [
            .binding("move_selection:down"), .binding("move_selection:down"), .binding("move_selection:down"),
        ])
        #expect(state.pending == .none)
        #expect(HelixKeymap.resolve(Self.letter("j"), state: &state) == [.binding("move_selection:down")])
    }

    @Test
    func digits_build_a_count_up_to_the_cap() {
        var state = CopyModeState()
        _ = Self.resolve([Self.letter("1"), Self.letter("2")], state: &state)
        #expect(state.pending == .count(12))
        _ = Self.resolve([Self.letter("0")], state: &state)
        #expect(state.pending == .count(120))
        _ = Self.resolve([Self.letter("9"), Self.letter("9")], state: &state)
        #expect(state.pending == .count(HelixKeymap.maximumCount))
    }

    @Test
    func a_leading_zero_is_no_count() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("0"), state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
    }

    @Test
    func a_count_repeats_word_motions_and_x_too() {
        var state = CopyModeState()
        #expect(Self.resolve([Self.letter("2"), Self.letter("w")], state: &state) == [
            .binding("collapse_selection"), .binding("extend_selection:word_next"),
            .binding("collapse_selection"), .binding("extend_selection:word_next"),
        ])
        #expect(Self.resolve([Self.letter("2"), Self.letter("x")], state: &state) == [
            .binding("select_line"), .binding("select_line"),
        ])
    }

    @Test
    func a_count_is_dropped_by_keys_that_do_not_take_one() {
        var state = CopyModeState()
        #expect(Self.resolve([Self.letter("4"), Self.letter("v")], state: &state) == [.selectMode(true)])
        #expect(state.pending == .none)
        #expect(Self.resolve([Self.letter("4"), Self.symbol(";")], state: &state) == [.binding("collapse_selection")])
        #expect(state.pending == .none)
        #expect(Self.resolve([Self.letter("4"), Self.letter("g"), Self.letter("g")], state: &state) == [
            .binding("extend_selection:top"),
        ])
        #expect(state.pending == .none)
    }

    // MARK: - Select mode and the selection

    @Test
    func v_toggles_select_mode() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("v"), state: &state) == [.selectMode(true)])
        #expect(state.selectMode)
        #expect(HelixKeymap.resolve(Self.letter("v"), state: &state) == [.selectMode(false)])
        #expect(!state.selectMode)
    }

    @Test
    func semicolon_collapses_and_option_semicolon_flips() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.symbol(";"), state: &state) == [.binding("collapse_selection")])
        let optionSemicolon = CopyModeKey(characters: "…", charactersIgnoringModifiers: ";", keyCode: 41, option: true)
        #expect(HelixKeymap.resolve(optionSemicolon, state: &state) == [.binding("flip_selection")])
    }

    @Test
    func percent_selects_all() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.symbol("%"), state: &state) == [.binding("select_all")])
    }

    @Test
    func y_copies_and_leaves_the_mode() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("y"), state: &state) == [.binding("copy_to_clipboard"), .exit])
    }

    // MARK: - Search

    @Test
    func slash_n_and_shift_n_drive_the_search() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.symbol("/"), state: &state) == [.binding("start_search")])
        #expect(HelixKeymap.resolve(Self.letter("n"), state: &state) == [.binding("navigate_search:next")])
        #expect(HelixKeymap.resolve(Self.letter("n", shift: true), state: &state) == [.binding("navigate_search:previous")])
    }

    // MARK: - Escape

    @Test
    func escape_clears_a_pending_prefix_first() {
        var state = CopyModeState()
        _ = HelixKeymap.resolve(Self.letter("g"), state: &state)
        #expect(HelixKeymap.resolve(Self.escape, state: &state)?.isEmpty == true)
        #expect(state.pending == .none)

        _ = HelixKeymap.resolve(Self.letter("5"), state: &state)
        #expect(HelixKeymap.resolve(Self.escape, state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
    }

    @Test
    func escape_leaves_select_mode_before_the_mode() {
        var state = CopyModeState()
        state.selectMode = true
        #expect(HelixKeymap.resolve(Self.escape, state: &state) == [.selectMode(false)])
        #expect(!state.selectMode)
        #expect(HelixKeymap.resolve(Self.escape, state: &state) == [.exit])
    }

    // MARK: - What is not the keymap's

    @Test
    func a_command_chord_is_not_the_keymaps_key() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.command("c"), state: &state) == nil)
        #expect(HelixKeymap.resolve(Self.command("w"), state: &state) == nil)
    }

    @Test
    func an_unbound_plain_key_is_swallowed() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("z"), state: &state)?.isEmpty == true)
        #expect(HelixKeymap.resolve(Self.symbol("#"), state: &state)?.isEmpty == true)
        #expect(HelixKeymap.resolve(Self.named(36), state: &state)?.isEmpty == true) // Return
    }

    @Test
    func an_option_chord_other_than_semicolon_is_swallowed() {
        var state = CopyModeState()
        #expect(HelixKeymap.resolve(Self.letter("j", option: true), state: &state)?.isEmpty == true)
    }

    @Test
    func a_shifted_letter_is_matched_by_its_letter() {
        var state = CopyModeState()
        // Shift+J is not bound; it must not read as `j`.
        #expect(HelixKeymap.resolve(Self.letter("j", shift: true), state: &state) == [.binding("move_selection:down")])
    }
}
