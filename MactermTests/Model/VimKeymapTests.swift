@testable import Macterm
import Testing

struct VimKeymapTests {
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
        CopyModeKey(characters: c, charactersIgnoringModifiers: c, keyCode: 0, shift: true)
    }

    private static func named(_ keyCode: UInt16) -> CopyModeKey {
        CopyModeKey(characters: "", charactersIgnoringModifiers: "", keyCode: keyCode)
    }

    private static let escape = named(53)

    private static func resolve(_ keys: [CopyModeKey], state: inout CopyModeState) -> [CopyModeCommand]? {
        var last: [CopyModeCommand]?
        for key in keys {
            last = VimKeymap.resolve(key, state: &state)
        }
        return last
    }

    // MARK: - Normal mode

    @Test
    func motions_move_in_normal_mode() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("h"), state: &state) == [.binding("move_selection:left")])
        #expect(VimKeymap.resolve(Self.letter("j"), state: &state) == [.binding("move_selection:down")])
        #expect(VimKeymap.resolve(Self.letter("k"), state: &state) == [.binding("move_selection:up")])
        #expect(VimKeymap.resolve(Self.letter("l"), state: &state) == [.binding("move_selection:right")])
        #expect(VimKeymap.resolve(Self.named(126), state: &state) == [.binding("move_selection:up")])
        #expect(VimKeymap.resolve(Self.control("u"), state: &state) == [.binding("move_selection:half_page_up")])
        #expect(VimKeymap.resolve(Self.named(116), state: &state) == [.binding("move_selection:page_up")])
    }

    @Test
    func word_motions_move_without_a_selection_and_w_lands_on_the_next_word() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("w"), state: &state) == [.binding("move_selection:next_word_start")])
        #expect(VimKeymap.resolve(Self.letter("e"), state: &state) == [.binding("move_selection:word_end")])
        #expect(VimKeymap.resolve(Self.letter("b"), state: &state) == [.binding("move_selection:word_prev")])
    }

    @Test
    func line_and_screen_motions() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("0"), state: &state) == [.binding("move_selection:line_start")])
        #expect(VimKeymap.resolve(Self.symbol("^"), state: &state) == [.binding("move_selection:line_start")])
        #expect(VimKeymap.resolve(Self.symbol("$"), state: &state) == [.binding("move_selection:line_end")])
        #expect(Self.resolve([Self.letter("g"), Self.letter("g")], state: &state) == [.binding("move_selection:top")])
        #expect(VimKeymap.resolve(Self.letter("g", shift: true), state: &state) == [.binding("move_selection:bottom")])
    }

    @Test
    func a_count_repeats_a_motion_and_a_zero_after_a_digit_is_part_of_it() {
        var state = CopyModeState()
        _ = Self.resolve([Self.letter("1"), Self.letter("0")], state: &state)
        #expect(state.pending == .count(10))
        #expect(VimKeymap.resolve(Self.letter("j"), state: &state)?.count == 10)
        #expect(state.pending == .none)
        #expect(Self.resolve([Self.letter("2"), Self.letter("w")], state: &state) == [
            .binding("move_selection:next_word_start"), .binding("move_selection:next_word_start"),
        ])
    }

    @Test
    func an_unknown_key_after_g_is_swallowed() {
        var state = CopyModeState()
        #expect(Self.resolve([Self.letter("g"), Self.letter("z")], state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
    }

    // MARK: - Visual modes

    @Test
    func v_starts_visual_mode_where_motions_extend() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("v"), state: &state)?.isEmpty == true)
        #expect(state.visual == .char)
        #expect(CopyModeKeymap.vim.label(for: state) == "Visual")
        #expect(VimKeymap.resolve(Self.letter("j"), state: &state) == [.binding("extend_selection:down")])
        #expect(VimKeymap.resolve(Self.letter("w"), state: &state) == [.binding("extend_selection:next_word_start")])
    }

    @Test
    func shift_v_is_visual_line_mode_and_every_motion_keeps_whole_lines() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("v", shift: true), state: &state) == [.binding("select_line_bounds")])
        #expect(state.visual == .line)
        #expect(CopyModeKeymap.vim.label(for: state) == "Visual Line")
        #expect(VimKeymap.resolve(Self.letter("j"), state: &state) == [
            .binding("extend_selection:down"), .binding("select_line_bounds"),
        ])
        #expect(VimKeymap.resolve(Self.letter("k"), state: &state) == [
            .binding("extend_selection:up"), .binding("select_line_bounds"),
        ])
    }

    @Test
    func control_v_is_visual_block_mode_on_a_rectangle() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.control("v"), state: &state) == [.binding("selection_rectangle:on")])
        #expect(state.visual == .block)
        #expect(CopyModeKeymap.vim.label(for: state) == "Visual Block")
        #expect(VimKeymap.resolve(Self.letter("l"), state: &state) == [.binding("extend_selection:right")])
        // Leaving block mode makes the selection lines again.
        #expect(VimKeymap.resolve(Self.escape, state: &state) == [
            .binding("selection_rectangle:off"), .binding("collapse_selection"),
        ])
        #expect(state.visual == .none)
    }

    @Test
    func the_same_key_again_leaves_its_visual_mode_and_collapses() {
        var state = CopyModeState()
        _ = VimKeymap.resolve(Self.letter("v"), state: &state)
        #expect(VimKeymap.resolve(Self.letter("v"), state: &state) == [.binding("collapse_selection")])
        #expect(state.visual == .none)
    }

    @Test
    func a_visual_mode_switches_to_another_in_place() {
        var state = CopyModeState()
        _ = VimKeymap.resolve(Self.letter("v"), state: &state)
        #expect(VimKeymap.resolve(Self.letter("v", shift: true), state: &state) == [.binding("select_line_bounds")])
        #expect(state.visual == .line)
        #expect(VimKeymap.resolve(Self.control("v"), state: &state) == [.binding("selection_rectangle:on")])
        #expect(state.visual == .block)
        #expect(VimKeymap.resolve(Self.letter("v"), state: &state) == [.binding("selection_rectangle:off")])
        #expect(state.visual == .char)
    }

    @Test
    func o_swaps_the_ends_only_in_visual_mode() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("o"), state: &state)?.isEmpty == true)
        _ = VimKeymap.resolve(Self.letter("v"), state: &state)
        #expect(VimKeymap.resolve(Self.letter("o"), state: &state) == [.binding("flip_selection")])
    }

    // MARK: - Yank and exit

    @Test
    func y_in_visual_mode_copies_and_leaves() {
        var state = CopyModeState()
        _ = VimKeymap.resolve(Self.letter("v"), state: &state)
        #expect(VimKeymap.resolve(Self.letter("y"), state: &state) == [.binding("copy_to_clipboard"), .exit])
    }

    @Test
    func yy_and_shift_y_copy_the_line() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("y"), state: &state)?.isEmpty == true)
        #expect(state.pending == .prefixY)
        #expect(VimKeymap.resolve(Self.letter("y"), state: &state) == [
            .binding("select_line_bounds"), .binding("copy_to_clipboard"), .exit,
        ])
        #expect(VimKeymap.resolve(Self.letter("y", shift: true), state: &state) == [
            .binding("select_line_bounds"), .binding("copy_to_clipboard"), .exit,
        ])
    }

    @Test
    func a_key_other_than_y_after_y_cancels_the_yank() {
        var state = CopyModeState()
        #expect(Self.resolve([Self.letter("y"), Self.letter("j")], state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
    }

    @Test
    func q_and_escape_leave_the_mode_from_normal_mode() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.letter("q"), state: &state) == [.exit])
        #expect(VimKeymap.resolve(Self.escape, state: &state) == [.exit])
    }

    @Test
    func escape_clears_a_prefix_then_leaves_visual_mode_then_the_mode() {
        var state = CopyModeState()
        _ = VimKeymap.resolve(Self.letter("5"), state: &state)
        #expect(VimKeymap.resolve(Self.escape, state: &state)?.isEmpty == true)
        #expect(state.pending == .none)
        _ = VimKeymap.resolve(Self.letter("v"), state: &state)
        #expect(VimKeymap.resolve(Self.escape, state: &state) == [.binding("collapse_selection")])
        #expect(state.visual == .none)
        #expect(VimKeymap.resolve(Self.escape, state: &state) == [.exit])
    }

    // MARK: - Search and what is not the keymap's

    @Test
    func slash_n_and_shift_n_drive_the_search() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.symbol("/"), state: &state) == [.binding("start_search")])
        #expect(VimKeymap.resolve(Self.letter("n"), state: &state) == [.binding("navigate_search:next")])
        #expect(VimKeymap.resolve(Self.letter("n", shift: true), state: &state) == [.binding("navigate_search:previous")])
    }

    @Test
    func a_command_chord_is_not_the_keymaps_key_and_an_unbound_key_is_swallowed() {
        var state = CopyModeState()
        #expect(VimKeymap.resolve(Self.command("c"), state: &state) == nil)
        #expect(VimKeymap.resolve(Self.letter("x"), state: &state)?.isEmpty == true)
        #expect(VimKeymap.resolve(Self.letter("j", option: true), state: &state)?.isEmpty == true)
    }

    @Test
    func the_helix_labels_follow_select_mode_and_the_vim_labels_the_visual_mode() {
        var state = CopyModeState()
        #expect(CopyModeKeymap.helix.label(for: state) == "Copy Mode")
        #expect(CopyModeKeymap.vim.label(for: state) == "Copy Mode")
        state.selectMode = true
        #expect(CopyModeKeymap.helix.label(for: state) == "Select Mode")
        #expect(CopyModeKeymap.vim.label(for: state) == "Copy Mode")
    }
}
