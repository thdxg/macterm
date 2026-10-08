import AppKit
@testable import Macterm
import Testing

/// Custom palettes' chords (`PaletteHotkeys`): stored by palette id in the
/// action bindings' grammar, matched like them, unbound by default.
@MainActor
struct PaletteHotkeysTests {
    private func keyDown(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test
    func a_palette_is_unbound_until_bound_and_its_chord_matches_the_way_an_actions_does() {
        let hotkeys = PaletteHotkeys.shared
        let priorIDs = hotkeys.paletteIDs
        defer {
            hotkeys.clearShortcut(paletteID: "k8s")
            hotkeys.paletteIDs = priorIDs
        }
        hotkeys.paletteIDs = ["k8s", "docker"]
        #expect(hotkeys.selectedShortcutString(paletteID: "k8s") == "none")
        let k = keyDown("k", keyCode: 40, flags: [.command, .shift])
        #expect(hotkeys.matchingPaletteID(for: k) == nil)

        hotkeys.setShortcutString("cmd+shift+k", paletteID: "k8s")
        #expect(Preferences.defaults.string(forKey: PaletteHotkeys.defaultsKey(paletteID: "k8s")) == "cmd+shift+k")
        #expect(hotkeys.matchingPaletteID(for: k) == "k8s")
        #expect(hotkeys.matchingPaletteID(for: keyDown("k", keyCode: 40, flags: [.command])) == nil, "the modifiers must match")
        #expect(hotkeys.shortcutStringsByRowID() == ["palette:k8s": "cmd+shift+k", "palette:docker": "none"])

        hotkeys.clearShortcut(paletteID: "k8s")
        #expect(hotkeys.matchingPaletteID(for: k) == nil)
        #expect(HotkeyRegistry.displaySymbols(for: hotkeys.selectedShortcutString(paletteID: "k8s")).isEmpty)
    }

    @Test
    func a_palette_no_longer_on_disk_stops_matching() {
        let hotkeys = PaletteHotkeys.shared
        let priorIDs = hotkeys.paletteIDs
        defer {
            hotkeys.clearShortcut(paletteID: "gone")
            hotkeys.paletteIDs = priorIDs
        }
        hotkeys.paletteIDs = ["gone"]
        hotkeys.setShortcutString("cmd+shift+g", paletteID: "gone")
        let g = keyDown("g", keyCode: 5, flags: [.command, .shift])
        #expect(hotkeys.matchingPaletteID(for: g) == "gone")
        hotkeys.paletteIDs = []
        #expect(hotkeys.matchingPaletteID(for: g) == nil, "the binding stays stored for the file's return, but matches nothing")
    }

    @Test
    func a_palettes_global_and_passthrough_flags_round_trip_and_the_gate_sees_them() {
        let hotkeys = PaletteHotkeys.shared
        let priorIDs = hotkeys.paletteIDs
        defer {
            hotkeys.clearShortcut(paletteID: "k8s")
            hotkeys.setPassesThrough(false, paletteID: "k8s")
            hotkeys.setGlobal(false, paletteID: "k8s")
            hotkeys.paletteIDs = priorIDs
        }
        hotkeys.paletteIDs = ["k8s"]
        #expect(!hotkeys.passesThrough(paletteID: "k8s"))
        #expect(!hotkeys.isGlobal(paletteID: "k8s"))
        #expect(hotkeys.passthroughPaletteIDs().isEmpty)
        #expect(hotkeys.globalPaletteIDs().isEmpty)

        hotkeys.setShortcutString("ctrl+k", paletteID: "k8s")
        hotkeys.setPassesThrough(true, paletteID: "k8s")
        #expect(hotkeys.passthroughPaletteIDs() == ["k8s"])
        #expect(Preferences.defaults.bool(forKey: PaletteHotkeys.passthroughDefaultsKey(paletteID: "k8s")))
        let k = keyDown("k", keyCode: 40, flags: [.control])
        #expect(KeybindPassthrough.matchedBinding(for: k) == .palette("k8s"), "the passthrough gate sees a flagged palette's chord")
        #expect(HotkeyBinding.palette("k8s").passesThroughToPrograms)
        #expect(
            !KeybindPassthrough.yields(binding: .palette("k8s"), pane: nil, programs: { ["nvim"] }, foregroundName: { _ in "nvim" }),
            "no pane, nothing to yield to"
        )

        hotkeys.setGlobal(true, paletteID: "k8s")
        #expect(hotkeys.globalPaletteIDs() == ["k8s"])
        #expect(HotkeyBinding.globalBindings.contains(.palette("k8s")))
        #expect(HotkeyBinding.palette("k8s").selectedShortcut?.id == "ctrl+k")
        #expect(HotkeyBinding.palette("k8s").id == "palette:k8s")
        #expect(HotkeyBinding.palette("k8s") < HotkeyBinding.palette("web"))
    }

    @Test
    func row_ids_round_trip_and_never_collide_with_an_action() {
        #expect(PaletteHotkeys.rowID(paletteID: "k8s") == "palette:k8s")
        #expect(PaletteHotkeys.paletteID(fromRowID: "palette:k8s") == "k8s")
        #expect(PaletteHotkeys.paletteID(fromRowID: "new_tab") == nil)
        for action in HotkeyAction.allCases {
            #expect(PaletteHotkeys.paletteID(fromRowID: action.id) == nil)
        }
    }
}
