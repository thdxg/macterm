import AppKit
@testable import Macterm
import Testing

@MainActor
struct HotkeysTests {
    // MARK: - parseShortcut

    @Test
    func parseShortcut_basic_cmd_key() throws {
        let s = try #require(HotkeyRegistry.parseShortcut("cmd+t"))
        #expect(s.modifiers.contains(.command))
        #expect(s.keyCode == 17) // t
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
        #expect(HotkeyRegistry.displayString(for: "") == "None")
        #expect(HotkeyRegistry.displayString(for: "none") == "None")
        #expect(HotkeyRegistry.displayString(for: "disabled") == "None")
    }

    // MARK: - displaySymbols

    @Test
    func displaySymbols_splits_modifiers_and_key() {
        // Glyphs follow the order tokens appear in the shortcut string, matching
        // displayString (which joins these same symbols).
        #expect(HotkeyRegistry.displaySymbols(for: "cmd+shift+a") == ["⌘", "⇧", "A"])
        #expect(HotkeyRegistry.displaySymbols(for: "cmd+ctrl+shift+opt+k") == ["⌘", "⌃", "⇧", "⌥", "K"])
    }

    @Test
    func displaySymbols_keeps_multichar_key_labels_whole() {
        #expect(HotkeyRegistry.displaySymbols(for: "cmd+tab") == ["⌘", "Tab"])
        #expect(HotkeyRegistry.displaySymbols(for: "cmd+space") == ["⌘", "Space"])
        #expect(HotkeyRegistry.displaySymbols(for: "cmd+escape") == ["⌘", "Esc"])
    }

    @Test
    func displaySymbols_empty_or_disabled() {
        #expect(HotkeyRegistry.displaySymbols(for: "").isEmpty)
        #expect(HotkeyRegistry.displaySymbols(for: "none").isEmpty)
        #expect(HotkeyRegistry.displaySymbols(for: "disabled").isEmpty)
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

    // MARK: - Hotkey Action keyToken

    @Test
    func parseShortcut_sets_keyToken_for_regular_key() throws {
        let s = try #require(HotkeyRegistry.parseShortcut("cmd+p"))
        #expect(s.keyToken == "p")
        #expect(s.keyCode == 35) // hardware keyCode for 'p' on QWERTY
    }

    @Test
    func parseShortcut_sets_keyToken_for_special_keys() throws {
        let tab = try #require(HotkeyRegistry.parseShortcut("ctrl+tab"))
        #expect(tab.keyToken == "tab")

        let ret = try #require(HotkeyRegistry.parseShortcut("cmd+return"))
        #expect(ret.keyToken == "return")

        let sp = try #require(HotkeyRegistry.parseShortcut("cmd+space"))
        #expect(sp.keyToken == "space")
    }

    // MARK: - shortcutString (logical-key capture)

    /// Simulate layout mismatch: characters = "p" but keyCode = 0 ('a' on QWERTY).
    @Test
    func shortcutString_captures_token_from_characters() throws {
        let pEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 0
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: pEvent))
        #expect(str == "cmd+p")
    }

    @Test
    func shortcutString_captures_special_key_from_characters() throws {
        let tabEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: tabEvent))
        #expect(str == "ctrl+tab")
    }

    @Test
    func shortcutString_captures_return_key() throws {
        let retEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: retEvent))
        #expect(str == "cmd+shift+return")
    }

    // MARK: - HotkeyShortcut.matches (logical-key)

    /// Character-based match succeeds despite wrong keyCode AZERTY-style mismatch.
    @Test
    func matches_succeeds_when_characters_match_token_regardless_of_keyCode() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+q"))
        let azertyEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 0
        ))
        #expect(shortcut.matches(azertyEvent))
    }

    /// Character mismatch should fail even if keyCode happens to match.
    @Test
    func matches_fails_when_characters_dont_match_even_if_keyCode_matches() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+q"))
        let wrongCharEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 12
        ))
        #expect(!shortcut.matches(wrongCharEvent))
    }

    @Test
    func matches_special_keys_by_token() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("ctrl+tab"))
        let tabEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        #expect(shortcut.matches(tabEvent))
    }

    @Test
    func matches_rejects_wrong_modifiers() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+p"))
        let wrongModEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control], // should be .command
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(!shortcut.matches(wrongModEvent))
    }

    // MARK: - HotkeyAction sanity

    @Test
    func all_actions_have_non_empty_titles() {
        for action in HotkeyAction.allCases {
            #expect(!action.title.isEmpty, "empty title for \(action.rawValue)")
        }
    }

    @Test
    func all_actions_have_valid_defaults() {
        // Every default must be a valid shortcut string — either a parseable
        // binding or the explicit "none"/disabled sentinel (some actions ship
        // unbound and are opt-in via Settings → Keymaps).
        for action in HotkeyAction.allCases {
            #expect(
                HotkeyRegistry.isValidShortcutString(action.defaultShortcut),
                "default shortcut for \(action.rawValue) is invalid: \(action.defaultShortcut)"
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

    // MARK: - Arrow key support (layout-independent by position)

    @Test
    func parseShortcut_arrow_keys() throws {
        let left = try #require(HotkeyRegistry.parseShortcut("cmd+left"))
        #expect(left.keyToken == "left")
        #expect(left.keyCode == 123)

        let right = try #require(HotkeyRegistry.parseShortcut("ctrl+right"))
        #expect(right.keyToken == "right")
        #expect(right.keyCode == 124)

        let down = try #require(HotkeyRegistry.parseShortcut("opt+down"))
        #expect(down.keyToken == "down")
        #expect(down.keyCode == 125)

        let up = try #require(HotkeyRegistry.parseShortcut("shift+up"))
        #expect(up.keyToken == "up")
        #expect(up.keyCode == 126)
    }

    // Arrow: characters = "", matched by keyCode fallback.
    @Test
    func matches_arrow_keys_by_position() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+left"))
        let leftEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123 // left arrow
        ))
        #expect(shortcut.matches(leftEvent))

        // Wrong arrow direction should not match.
        let rightEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124 // right arrow — should NOT match "cmd+left"
        ))
        #expect(!shortcut.matches(rightEvent))
    }

    @Test
    func shortcutString_captures_arrow_key_from_keyCode() throws {
        let leftEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125 // down arrow
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: leftEvent))
        #expect(str == "cmd+down")
    }

    @Test
    func displayString_arrow_keys() {
        #expect(HotkeyRegistry.displayString(for: "cmd+left") == "⌘←")
        #expect(HotkeyRegistry.displayString(for: "cmd+right") == "⌘→")
        #expect(HotkeyRegistry.displayString(for: "cmd+up") == "⌘↑")
        #expect(HotkeyRegistry.displayString(for: "cmd+down") == "⌘↓")
    }

    /// Real hardware arrow-key NSEvents carry `.numericPad`/`.function` in
    /// `modifierFlags` — unlike the synthetic events above, which only set the
    /// modifiers passed in. Matching must ignore those bits (#106) or every
    /// arrow-key binding fails against a live keypress despite passing the
    /// hand-rolled synthetic-event tests.
    @Test
    func matches_arrow_key_with_real_hardware_modifier_flags() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+opt+right"))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .numericPad, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124 // right arrow
        ))
        #expect(shortcut.matches(event))
    }

    // MARK: - Escape key support

    @Test
    func parseShortcut_escape() throws {
        let esc = try #require(HotkeyRegistry.parseShortcut("cmd+escape"))
        #expect(esc.keyToken == "escape")
        #expect(esc.keyCode == 53)
    }

    @Test
    func matches_escape_key() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+escape"))
        let escEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        #expect(shortcut.matches(escEvent))
    }

    @Test
    func shortcutString_captures_escape() throws {
        let escEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: escEvent))
        #expect(str == "cmd+escape")
    }

    @Test
    func displayString_escape() {
        #expect(HotkeyRegistry.displayString(for: "cmd+escape") == "⌘Esc")
    }

    // MARK: - Colemak-like layout mismatch

    // Colemak: QWERTY P position (keyCode 35) produces "d". Should NOT match "cmd+p".
    @Test
    func colemak_mismatch_char_and_keyCode_both_wrong_does_not_match() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+p"))
        let colemakEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 35
        ))
        #expect(!shortcut.matches(colemakEvent))

        // But should match "cmd+d" since that's what was actually typed.
        let dShortcut = try #require(HotkeyRegistry.parseShortcut("cmd+d"))
        #expect(dShortcut.matches(colemakEvent))
    }

    // MARK: - Shifted-symbol regression (charactersIgnoringModifiers != base key)

    /// cmd+shift+,  →  charactersIgnoringModifiers="<", keyCode=43.
    /// Should match stored token "," via keyCode fallback.
    @Test
    func shifted_symbol_match_falls_back_to_keyCode() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+shift+,"))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "<",
            charactersIgnoringModifiers: "<",
            isARepeat: false,
            keyCode: 43
        ))
        #expect(shortcut.matches(event))
    }

    /// Same shifted symbol but without shift modifier should NOT match.
    @Test
    func shifted_symbol_wrong_modifiers_does_not_match() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+shift+,"))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command], // no shift
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 43
        ))
        #expect(!shortcut.matches(event))
    }

    /// shift+/  →  charactersIgnoringModifiers="?", keyCode=44.
    /// shortcutString should capture as "shift+/".
    @Test
    func shortcutString_shifted_slash_captures_base_token() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "?",
            charactersIgnoringModifiers: "?",
            isARepeat: false,
            keyCode: 44
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: event))
        #expect(str == "shift+/")
    }

    /// cmd+shift+/  (e.g. a hypothetical shortcut) should also work.
    @Test
    func shifted_slash_match_with_command() throws {
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+shift+/"))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "?",
            charactersIgnoringModifiers: "?",
            isARepeat: false,
            keyCode: 44
        ))
        #expect(shortcut.matches(event))
    }

    /// Ensure letter shortcuts still use character-based matching even when
    /// keyCode differs (Colemak/AZERTY). The keyCode fallback must NOT
    /// cause a mismatched letter to match.
    @Test
    func colemak_letter_uses_char_not_keyCode_fallback() throws {
        // User presses the key at QWERTY keyCode 35 (P position),
        // which produces "d" in Colemak.
        // "cmd+p" should NOT match — the char "d" is a known token,
        // so it takes precedence over keyCode fallback.
        let shortcut = try #require(HotkeyRegistry.parseShortcut("cmd+p"))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 35 // P's keyCode
        ))
        #expect(!shortcut.matches(event))

        // "cmd+d" should match.
        let dShortcut = try #require(HotkeyRegistry.parseShortcut("cmd+d"))
        #expect(dShortcut.matches(event))
    }

    /// Letters should also be captured correctly by shortcutString.
    @Test
    func shortcutString_letter_captures_by_char_not_keyCode() throws {
        // keyCode=0 is 'a' on QWERTY; characters="q" (AZERTY-style)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 0 // 'a' keyCode
        ))
        let str = try #require(HotkeyRegistry.shortcutString(from: event))
        #expect(str == "cmd+q") // Should be "q", not "a"
    }

    // MARK: - Conflict detection

    @Test
    func conflictKey_ignores_modifier_order() {
        #expect(HotkeyRegistry.conflictKey(for: "cmd+shift+d")
            == HotkeyRegistry.conflictKey(for: "shift+cmd+d"))
    }

    @Test
    func conflictKey_distinguishes_modifiers_and_keys() {
        #expect(HotkeyRegistry.conflictKey(for: "cmd+d")
            != HotkeyRegistry.conflictKey(for: "cmd+shift+d"))
        #expect(HotkeyRegistry.conflictKey(for: "cmd+d")
            != HotkeyRegistry.conflictKey(for: "cmd+t"))
    }

    @Test
    func conflictKey_is_nil_for_disabled_or_invalid() {
        #expect(HotkeyRegistry.conflictKey(for: "disabled") == nil)
        #expect(HotkeyRegistry.conflictKey(for: "") == nil)
        #expect(HotkeyRegistry.conflictKey(for: "cmd+") == nil)
    }

    @Test
    func conflictingActionIDs_flags_shared_bindings() {
        let conflicts = HotkeyRegistry.conflictingActionIDs(in: [
            "a": "cmd+t",
            "b": "shift+cmd+t", // distinct
            "c": "cmd+t", // collides with a
            "d": "cmd+w",
        ])
        #expect(conflicts == ["a", "c"])
    }

    @Test
    func conflictingActionIDs_ignores_disabled_duplicates() {
        let conflicts = HotkeyRegistry.conflictingActionIDs(in: [
            "a": "disabled",
            "b": "disabled",
            "c": "cmd+t",
        ])
        #expect(conflicts.isEmpty)
    }

    // MARK: - HotkeyRegistry.matches (the static cache path)
    //
    // The static `matches(event:action:)` runs the parsed-shortcut cache — the
    // path `KeyRouter`/`isAppShortcut` actually use per keystroke. It was
    // previously untested, which let a cache regression (every hotkey silently
    // failing) ship. These lock the default bindings AND the cache invalidation.

    private func keyEvent(_ chars: String, _ mods: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        ))
    }

    @Test
    func registry_matches_default_bindings_through_the_cache() throws {
        // cmd+d = splitRight, cmd+w = closePane — the bindings the user reported
        // as broken. Call twice each: the second call is a cache HIT and must
        // still match (a broken cache returns a stale/nil shortcut → no match).
        let cmdD = try keyEvent("d", [.command], keyCode: 2)
        #expect(HotkeyRegistry.matches(cmdD, action: .splitRight))
        #expect(HotkeyRegistry.matches(cmdD, action: .splitRight))
        #expect(!HotkeyRegistry.matches(cmdD, action: .closePane))

        let cmdW = try keyEvent("w", [.command], keyCode: 13)
        #expect(HotkeyRegistry.matches(cmdW, action: .closePane))
        #expect(HotkeyRegistry.matches(cmdW, action: .closePane))
    }

    @Test
    func registry_matches_reflects_a_rebind_after_cache_invalidation() throws {
        // Rebinding must invalidate the cached parse so the next match uses the
        // new binding. Save/restore the (test-suite) defaults to avoid leakage.
        let action = HotkeyAction.splitRight
        let prior = Preferences.defaults.string(forKey: action.defaultsKey)
        defer {
            if let prior { HotkeyRegistry.setShortcutString(prior, for: action) }
            else { HotkeyRegistry.setShortcutString(action.defaultShortcut, for: action) }
        }

        // Prime the cache with the default (cmd+d).
        let cmdD = try keyEvent("d", [.command], keyCode: 2)
        #expect(HotkeyRegistry.matches(cmdD, action: action))

        // Rebind to cmd+e; the old key must stop matching and the new one start.
        HotkeyRegistry.setShortcutString("cmd+e", for: action)
        let cmdE = try keyEvent("e", [.command], keyCode: 14)
        #expect(!HotkeyRegistry.matches(cmdD, action: action))
        #expect(HotkeyRegistry.matches(cmdE, action: action))
    }
}
