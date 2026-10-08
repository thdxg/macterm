import AppKit
import Foundation
import os

/// Chords for custom palettes (`CustomPaletteStore`), beside the
/// `HotkeyAction` table. A palette defined in a file cannot be a case of
/// that enum — App Intents restate its cases, Carbon registration indexes
/// them — so its binding lives here, keyed by the palette's id, in the same
/// shortcut grammar (`HotkeyRegistry.parseShortcut`) under
/// `macterm.hotkey.palette.<id>`, with the same two flags beside it
/// (`.passthrough`, `.global`), so a palette's chord takes Pass to TUI and
/// Global exactly as an action's does — `HotkeyBinding.palette` is how the
/// registration and the passthrough gate see it. Unbound by default.
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
        didSet {
            guard paletteIDs != oldValue else { return }
            shortcuts = nil
            // A file added or removed changes which palettes can hold a
            // global chord.
            GlobalHotkeys.shared.sync()
        }
    }

    /// Parsed chords by palette id, built on first use after a change.
    @ObservationIgnored private var shortcuts: [String: HotkeyShortcut]?

    nonisolated static func defaultsKey(paletteID: String) -> String {
        "macterm.hotkey.palette.\(paletteID)"
    }

    nonisolated static func passthroughDefaultsKey(paletteID: String) -> String {
        "macterm.hotkey.palette.\(paletteID).passthrough"
    }

    nonisolated static func globalDefaultsKey(paletteID: String) -> String {
        "macterm.hotkey.palette.\(paletteID).global"
    }

    /// Carbon identifies a hot key by a `UInt32`; a palette gets one from
    /// here, stable for the life of the process (the ids are never
    /// persisted), above every action's (`GlobalHotkeys.hotKeyID`).
    nonisolated static let carbonIDBase: UInt32 = 1000
    @ObservationIgnored private var carbonIDs: [String: UInt32] = [:]

    func carbonID(paletteID: String) -> UInt32 {
        if let id = carbonIDs[paletteID] { return id }
        let id = Self.carbonIDBase + UInt32(carbonIDs.count)
        carbonIDs[paletteID] = id
        return id
    }

    func paletteID(forCarbonID id: UInt32) -> String? {
        carbonIDs.first { $0.value == id }?.key
    }

    func passesThrough(paletteID: String) -> Bool {
        Preferences.defaults.bool(forKey: Self.passthroughDefaultsKey(paletteID: paletteID))
    }

    /// Flag or unflag passthrough and reconcile Carbon at once: the two flags
    /// contradict each other, so a global registration is refused while
    /// passthrough is on (`GlobalHotkeyPlan.precheck`).
    func setPassesThrough(_ enabled: Bool, paletteID: String) {
        Preferences.defaults.set(enabled, forKey: Self.passthroughDefaultsKey(paletteID: paletteID))
        GlobalHotkeys.shared.sync()
    }

    func isGlobal(paletteID: String) -> Bool {
        Preferences.defaults.bool(forKey: Self.globalDefaultsKey(paletteID: paletteID))
    }

    func setGlobal(_ enabled: Bool, paletteID: String) {
        Preferences.defaults.set(enabled, forKey: Self.globalDefaultsKey(paletteID: paletteID))
        GlobalHotkeys.shared.sync()
    }

    /// The palettes on disk flagged to pass through, in file order.
    func passthroughPaletteIDs() -> [String] {
        paletteIDs.filter { passesThrough(paletteID: $0) }
    }

    /// The palettes on disk flagged global, in file order.
    func globalPaletteIDs() -> [String] {
        paletteIDs.filter { isGlobal(paletteID: $0) }
    }

    /// The parsed chord of a palette on disk, nil when unbound or unknown.
    func shortcut(paletteID: String) -> HotkeyShortcut? {
        parsedShortcuts()[paletteID]
    }

    /// The row id Settings → Keymaps captures under, distinct from any
    /// `HotkeyAction.id`.
    nonisolated static func rowID(paletteID: String) -> String {
        "palette:\(paletteID)"
    }

    nonisolated static func paletteID(fromRowID rowID: String) -> String? {
        rowID.hasPrefix("palette:") ? String(rowID.dropFirst("palette:".count)) : nil
    }

    func selectedShortcutString(paletteID: String) -> String {
        Preferences.defaults.string(forKey: Self.defaultsKey(paletteID: paletteID)) ?? "none"
    }

    func setShortcutString(_ shortcut: String, paletteID: String) {
        Preferences.defaults.set(shortcut, forKey: Self.defaultsKey(paletteID: paletteID))
        shortcuts = nil
        Preferences.shared.bumpHotkeyVersion()
        // A global-flagged palette's registration follows its chord.
        GlobalHotkeys.shared.sync()
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
