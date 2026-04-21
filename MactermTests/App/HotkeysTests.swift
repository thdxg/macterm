import AppKit
@testable import Macterm
import XCTest

@MainActor
final class HotkeysTests: XCTestCase {
    // MARK: - parseShortcut

    func test_parseShortcut_basic_cmd_key() throws {
        let s = HotkeyRegistry.parseShortcut("cmd+t")
        XCTAssertNotNil(s)
        XCTAssertTrue(try XCTUnwrap(s?.modifiers.contains(.command)))
        XCTAssertEqual(s?.keyCode, 17) // t
    }

    func test_parseShortcut_multiple_modifiers_in_any_order() {
        let a = HotkeyRegistry.parseShortcut("cmd+shift+p")
        let b = HotkeyRegistry.parseShortcut("shift+cmd+p")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.modifiers, b?.modifiers)
        XCTAssertEqual(a?.keyCode, b?.keyCode)
    }

    func test_parseShortcut_accepts_aliases() {
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("command+t"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("control+t"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("option+t"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("alt+t"))
    }

    func test_parseShortcut_symbol_keys() {
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("cmd+\\"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("cmd+["))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("cmd+]"))
    }

    func test_parseShortcut_special_keys() {
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("ctrl+tab"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("cmd+return"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("cmd+space"))
    }

    func test_parseShortcut_disabled_returns_nil() {
        XCTAssertNil(HotkeyRegistry.parseShortcut("none"))
        XCTAssertNil(HotkeyRegistry.parseShortcut("disabled"))
        XCTAssertNil(HotkeyRegistry.parseShortcut(""))
    }

    func test_parseShortcut_unknown_key_returns_nil() {
        XCTAssertNil(HotkeyRegistry.parseShortcut("cmd+notakey"))
    }

    func test_parseShortcut_unknown_modifier_returns_nil() {
        XCTAssertNil(HotkeyRegistry.parseShortcut("bogus+t"))
    }

    func test_parseShortcut_is_case_insensitive() {
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("CMD+T"))
        XCTAssertNotNil(HotkeyRegistry.parseShortcut("Cmd+T"))
    }

    // MARK: - displayString

    func test_displayString_renders_modifiers_in_apple_order() {
        // Our order: cmd, ctrl, shift, option → ⌘⌃⇧⌥
        let s = HotkeyRegistry.displayString(for: "cmd+ctrl+shift+opt+k")
        XCTAssertEqual(s, "⌘⌃⇧⌥K")
    }

    func test_displayString_formats_special_keys() {
        XCTAssertEqual(HotkeyRegistry.displayString(for: "cmd+tab"), "⌘Tab")
        XCTAssertEqual(HotkeyRegistry.displayString(for: "cmd+space"), "⌘Space")
        XCTAssertEqual(HotkeyRegistry.displayString(for: "cmd+return"), "⌘↩")
    }

    func test_displayString_empty_or_disabled() {
        XCTAssertEqual(HotkeyRegistry.displayString(for: ""), "Disabled")
        XCTAssertEqual(HotkeyRegistry.displayString(for: "none"), "Disabled")
        XCTAssertEqual(HotkeyRegistry.displayString(for: "disabled"), "Disabled")
    }

    // MARK: - isValidShortcutString

    func test_isValid_accepts_empty_and_disabled() {
        XCTAssertTrue(HotkeyRegistry.isValidShortcutString(""))
        XCTAssertTrue(HotkeyRegistry.isValidShortcutString("none"))
        XCTAssertTrue(HotkeyRegistry.isValidShortcutString("disabled"))
    }

    func test_isValid_accepts_wellformed() {
        XCTAssertTrue(HotkeyRegistry.isValidShortcutString("cmd+shift+p"))
    }

    func test_isValid_rejects_garbage() {
        XCTAssertFalse(HotkeyRegistry.isValidShortcutString("cmd+notakey"))
        XCTAssertFalse(HotkeyRegistry.isValidShortcutString("bogus+t"))
    }

    // MARK: - HotkeyAction sanity

    func test_all_actions_have_non_empty_titles() {
        for action in HotkeyAction.allCases {
            XCTAssertFalse(action.title.isEmpty, "empty title for \(action.rawValue)")
        }
    }

    func test_all_actions_have_parseable_defaults() {
        for action in HotkeyAction.allCases {
            XCTAssertNotNil(
                HotkeyRegistry.parseShortcut(action.defaultShortcut),
                "default shortcut for \(action.rawValue) fails to parse: \(action.defaultShortcut)"
            )
        }
    }

    func test_all_action_ids_are_unique() {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func test_all_action_defaultsKeys_are_unique() {
        let keys = HotkeyAction.allCases.map(\.defaultsKey)
        XCTAssertEqual(keys.count, Set(keys).count)
    }
}
