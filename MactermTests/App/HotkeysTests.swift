import AppKit
@testable import Macterm
import Testing

@MainActor
struct HotkeysTests {
    // MARK: - parseShortcut

    @Test
    func parseShortcut_basic_cmd_key() throws {
        let s = HotkeyRegistry.parseShortcut("cmd+t")
        #expect(s != nil)
        #expect(try #require(s?.modifiers.contains(.command)))
        #expect(s?.keyCode == 17) // t
    }

    @Test
    func parseShortcut_multiple_modifiers_in_any_order() {
        let a = HotkeyRegistry.parseShortcut("cmd+shift+p")
        let b = HotkeyRegistry.parseShortcut("shift+cmd+p")
        #expect(a != nil)
        #expect(b != nil)
        #expect(a?.modifiers == b?.modifiers)
        #expect(a?.keyCode == b?.keyCode)
    }

    @Test
    func parseShortcut_accepts_aliases() {
        #expect(HotkeyRegistry.parseShortcut("command+t") != nil)
        #expect(HotkeyRegistry.parseShortcut("control+t") != nil)
        #expect(HotkeyRegistry.parseShortcut("option+t") != nil)
        #expect(HotkeyRegistry.parseShortcut("alt+t") != nil)
    }

    @Test
    func parseShortcut_symbol_keys() {
        #expect(HotkeyRegistry.parseShortcut("cmd+\\") != nil)
        #expect(HotkeyRegistry.parseShortcut("cmd+[") != nil)
        #expect(HotkeyRegistry.parseShortcut("cmd+]") != nil)
    }

    @Test
    func parseShortcut_special_keys() {
        #expect(HotkeyRegistry.parseShortcut("ctrl+tab") != nil)
        #expect(HotkeyRegistry.parseShortcut("cmd+return") != nil)
        #expect(HotkeyRegistry.parseShortcut("cmd+space") != nil)
    }

    @Test
    func parseShortcut_disabled_returns_nil() {
        #expect(HotkeyRegistry.parseShortcut("none") == nil)
        #expect(HotkeyRegistry.parseShortcut("disabled") == nil)
        #expect(HotkeyRegistry.parseShortcut("") == nil)
    }

    @Test
    func parseShortcut_unknown_key_returns_nil() {
        #expect(HotkeyRegistry.parseShortcut("cmd+notakey") == nil)
    }

    @Test
    func parseShortcut_unknown_modifier_returns_nil() {
        #expect(HotkeyRegistry.parseShortcut("bogus+t") == nil)
    }

    @Test
    func parseShortcut_is_case_insensitive() {
        #expect(HotkeyRegistry.parseShortcut("CMD+T") != nil)
        #expect(HotkeyRegistry.parseShortcut("Cmd+T") != nil)
    }

    // MARK: - displayString

    @Test
    func displayString_renders_modifiers_in_apple_order() {
        // Our order: cmd, ctrl, shift, option → ⌘⌃⇧⌥
        let s = HotkeyRegistry.displayString(for: "cmd+ctrl+shift+opt+k")
        #expect(s == "⌘⌃⇧⌥K")
    }

    @Test
    func displayString_formats_special_keys() {
        #expect(HotkeyRegistry.displayString(for: "cmd+tab") == "⌘Tab")
        #expect(HotkeyRegistry.displayString(for: "cmd+space") == "⌘Space")
        #expect(HotkeyRegistry.displayString(for: "cmd+return") == "⌘↩")
    }

    @Test
    func displayString_empty_or_disabled() {
        #expect(HotkeyRegistry.displayString(for: "") == "Disabled")
        #expect(HotkeyRegistry.displayString(for: "none") == "Disabled")
        #expect(HotkeyRegistry.displayString(for: "disabled") == "Disabled")
    }

    // MARK: - isValidShortcutString

    @Test
    func isValid_accepts_empty_and_disabled() {
        #expect(HotkeyRegistry.isValidShortcutString(""))
        #expect(HotkeyRegistry.isValidShortcutString("none"))
        #expect(HotkeyRegistry.isValidShortcutString("disabled"))
    }

    @Test
    func isValid_accepts_wellformed() {
        #expect(HotkeyRegistry.isValidShortcutString("cmd+shift+p"))
    }

    @Test
    func isValid_rejects_garbage() {
        #expect(!HotkeyRegistry.isValidShortcutString("cmd+notakey"))
        #expect(!HotkeyRegistry.isValidShortcutString("bogus+t"))
    }

    // MARK: - HotkeyAction sanity

    @Test
    func all_actions_have_non_empty_titles() {
        for action in HotkeyAction.allCases {
            #expect(!action.title.isEmpty, "empty title for \(action.rawValue)")
        }
    }

    @Test
    func all_actions_have_parseable_defaults() {
        for action in HotkeyAction.allCases {
            #expect(
                HotkeyRegistry.parseShortcut(action.defaultShortcut) != nil,
                "default shortcut for \(action.rawValue) fails to parse: \(action.defaultShortcut)"
            )
        }
    }

    @Test
    func all_action_ids_are_unique() {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        #expect(ids.count == Set(ids).count)
    }

    @Test
    func all_action_defaultsKeys_are_unique() {
        let keys = HotkeyAction.allCases.map(\.defaultsKey)
        #expect(keys.count == Set(keys).count)
    }
}
