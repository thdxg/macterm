import AppKit

/// A chord's owner: one of the built-in actions, or a custom palette
/// (`PaletteHotkeys`), which cannot be a `HotkeyAction` case because that
/// enum is restated by App Intents and indexed by the Carbon registration.
/// Everything that treats a chord generically — the global registration,
/// the passthrough gate, the Keymaps rows — keys on this, so a palette's
/// chord gets Global and Pass to TUI exactly as an action's does.
enum HotkeyBinding: Hashable, Comparable {
    case action(HotkeyAction)
    case palette(String)

    /// The Keymaps row id, and the name in logs.
    var id: String {
        switch self {
        case let .action(action): action.id
        case let .palette(paletteID): PaletteHotkeys.rowID(paletteID: paletteID)
        }
    }

    static func < (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.id < rhs.id
    }

    /// `palettes` is the table that a palette's chord and flags come from.
    /// Only a test gives another one.
    @MainActor
    func selectedShortcut(palettes: PaletteHotkeys = .shared) -> HotkeyShortcut? {
        switch self {
        case let .action(action): HotkeyRegistry.selectedShortcut(for: action)
        case let .palette(paletteID): palettes.shortcut(paletteID: paletteID)
        }
    }

    @MainActor
    func passesThroughToPrograms(palettes: PaletteHotkeys = .shared) -> Bool {
        switch self {
        case let .action(action): HotkeyRegistry.passesThroughToPrograms(for: action)
        case let .palette(paletteID): palettes.passesThrough(paletteID: paletteID)
        }
    }

    @MainActor
    func matches(_ event: NSEvent, palettes: PaletteHotkeys = .shared) -> Bool {
        selectedShortcut(palettes: palettes)?.matches(event) == true
    }

    /// Every binding flagged global: the actions, then the palettes.
    @MainActor
    static func globalBindings(palettes: PaletteHotkeys = .shared) -> [HotkeyBinding] {
        HotkeyRegistry.globalActions().map(HotkeyBinding.action)
            + palettes.globalPaletteIDs().map(HotkeyBinding.palette)
    }

    /// Every binding flagged to pass through to programs.
    @MainActor
    static func passthroughBindings(palettes: PaletteHotkeys = .shared) -> [HotkeyBinding] {
        HotkeyRegistry.passthroughActions().map(HotkeyBinding.action)
            + palettes.passthroughPaletteIDs().map(HotkeyBinding.palette)
    }
}
