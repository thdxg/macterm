import AppKit
import Foundation
import os

/// Chords for custom palettes (`CustomPaletteStore`), beside the
/// `HotkeyAction` table. A palette defined in a file cannot be a case of
/// that enum — App Intents restate its cases, Carbon registration indexes
/// them — so its binding lives here, keyed by the palette's id, in the same
/// shortcut grammar (`HotkeyRegistry.parseShortcut`) under
/// `macterm.hotkey.palette.<id>`. Unbound by default. Local only: no
/// passthrough and no global registration, which keeps the one-owner rules
/// of `KeyRouter` and `GlobalHotkeys` untouched.
///
/// Three places ask the same question — "is this keyDown a custom
/// palette's chord?" — and must agree: `MainAppResponder` (open the palette
/// on it), `PaletteResponder` (switch to it while the palette is up) and
/// `GhosttyTerminalNSView.isAppShortcut` (keep it from libghostty).
/// `matchingPaletteID` is that one answer.
@MainActor @Observable
final class PaletteHotkeys {
    static let shared = PaletteHotkeys()

    /// Every palette file's id, bound or not — set by the store on each
    /// load, so a file added after launch is matchable at once.
    var paletteIDs: [String] = [] {
        didSet { if paletteIDs != oldValue { shortcuts = nil } }
    }

    /// Parsed chords by palette id, built on first use after a change.
    @ObservationIgnored private var shortcuts: [String: HotkeyShortcut]?

    static func defaultsKey(paletteID: String) -> String {
        "macterm.hotkey.palette.\(paletteID)"
    }

    /// The row id Settings → Keymaps captures under, distinct from any
    /// `HotkeyAction.id`.
    static func rowID(paletteID: String) -> String {
        "palette:\(paletteID)"
    }

    static func paletteID(fromRowID rowID: String) -> String? {
        rowID.hasPrefix("palette:") ? String(rowID.dropFirst("palette:".count)) : nil
    }

    func selectedShortcutString(paletteID: String) -> String {
        Preferences.defaults.string(forKey: Self.defaultsKey(paletteID: paletteID)) ?? "none"
    }

    func setShortcutString(_ shortcut: String, paletteID: String) {
        Preferences.defaults.set(shortcut, forKey: Self.defaultsKey(paletteID: paletteID))
        shortcuts = nil
        Preferences.shared.bumpHotkeyVersion()
    }

    /// Clear a palette's chord — when the row is cleared in Settings.
    func clearShortcut(paletteID: String) {
        setShortcutString("disabled", paletteID: paletteID)
    }

    private func parsedShortcuts() -> [String: HotkeyShortcut] {
        if let shortcuts { return shortcuts }
        var built: [String: HotkeyShortcut] = [:]
        for id in paletteIDs {
            if let shortcut = HotkeyRegistry.parseShortcut(selectedShortcutString(paletteID: id)) {
                built[id] = shortcut
            }
        }
        shortcuts = built
        return built
    }

    /// The palette whose chord `event` is, bound or not enabled alike — the
    /// caller decides what a turned-off palette's chord says. Ties go to the
    /// first file by name, as `HotkeyAction.allCases` order does for actions.
    func matchingPaletteID(for event: NSEvent) -> String? {
        let shortcuts = parsedShortcuts()
        guard !shortcuts.isEmpty else { return nil }
        return paletteIDs.first { shortcuts[$0]?.matches(event) == true }
    }

    /// Every custom palette's current chord by its Keymaps row id, for the
    /// conflict check beside the action bindings.
    func shortcutStringsByRowID() -> [String: String] {
        Dictionary(uniqueKeysWithValues: paletteIDs.map { (Self.rowID(paletteID: $0), selectedShortcutString(paletteID: $0)) })
    }
}
