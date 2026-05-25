import AppKit
import Foundation

@MainActor
final class HotkeyCaptureState {
    static let shared = HotkeyCaptureState()
    var isCapturing = false
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case newTab = "new_tab"
    case closePane = "close_pane"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case toggleSidebar = "toggle_sidebar"
    case recentTab = "recent_tab"
    case nextProject = "next_project"
    case previousProject = "previous_project"
    case nextGlobalTab = "next_global_tab"
    case previousGlobalTab = "previous_global_tab"
    case focusPaneLeft = "focus_pane_left"
    case focusPaneDown = "focus_pane_down"
    case focusPaneUp = "focus_pane_up"
    case focusPaneRight = "focus_pane_right"
    case resizePaneLeft = "resize_pane_left"
    case resizePaneDown = "resize_pane_down"
    case resizePaneUp = "resize_pane_up"
    case resizePaneRight = "resize_pane_right"
    case closeWindow = "close_window"
    case openProject = "open_project"
    case zoomPane = "zoom_pane"
    case toggleCommandPalette = "toggle_command_palette"
    case reloadGhosttyConfig = "reload_ghostty_config"
    case toggleQuickTerminal = "toggle_quick_terminal"

    var id: String { rawValue }

    /// User-facing name. Sourced from `AppCommand` so the palette and
    /// Settings don't drift apart.
    var title: String { appCommand.title }

    var defaultsKey: String { "macterm.hotkey.\(rawValue)" }

    var defaultShortcut: String {
        switch self {
        case .newTab: "cmd+t"
        case .closePane: "cmd+w"
        case .splitRight: "cmd+d"
        case .splitDown: "cmd+shift+d"
        case .toggleSidebar: "cmd+\\"
        case .recentTab: "ctrl+tab"
        case .nextProject: "cmd+]"
        case .previousProject: "cmd+["
        case .nextGlobalTab: "ctrl+]"
        case .previousGlobalTab: "ctrl+["
        case .focusPaneLeft: "cmd+ctrl+h"
        case .focusPaneDown: "cmd+ctrl+j"
        case .focusPaneUp: "cmd+ctrl+k"
        case .focusPaneRight: "cmd+ctrl+l"
        case .resizePaneLeft: "cmd+shift+h"
        case .resizePaneDown: "cmd+shift+j"
        case .resizePaneUp: "cmd+shift+k"
        case .resizePaneRight: "cmd+shift+l"
        case .closeWindow: "cmd+shift+w"
        case .openProject: "cmd+o"
        case .zoomPane: "cmd+shift+return"
        case .toggleCommandPalette: "cmd+p"
        case .reloadGhosttyConfig: "cmd+shift+,"
        case .toggleQuickTerminal: "ctrl+`"
        }
    }
}

struct HotkeyShortcut: Identifiable {
    let id: String
    let keyCode: UInt16 // Hardware keyCode for Carbon global hotkey registration.
    let keyToken: String // Logical key token used for local NSEvent matching.
    let modifiers: NSEvent.ModifierFlags

    /// Match by logical character, not hardware keyCode.
    func matches(_ event: NSEvent) -> Bool {
        guard let token = HotkeyRegistry.eventToken(event),
              token == keyToken
        else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
    }
}

enum HotkeyRegistry {
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36,
        "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50,
        "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// Reverse mapping: hardware keyCode → base key token.
    /// Used as a fallback when `charactersIgnoringModifiers` yields a shifted
    /// symbol (e.g. `<` from `shift+,`) that is not itself a valid key token.
    /// Populated from one representative per keyCode (lowercase for letters,
    /// unshifted for symbols).
    private static let keyCodeToBaseToken: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        // Letters → lowercase
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            if let code = keyCodes[String(letter)] { result[code] = String(letter) }
        }
        // Digits → digit
        for digit in "0123456789" {
            if let code = keyCodes[String(digit)] { result[code] = String(digit) }
        }
        // Symbols and special keys — pick the unshifted/base form per keyCode.
        let baseEntries: [String: UInt16] = [
            "=": 24, "-": 27, "]": 30, "[": 33,
            "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47,
            "tab": 48, "space": 49, "`": 50,
            "return": 36, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (token, code) in baseEntries {
            result[code] = token
        }
        return result
    }()

    private static let modifierOnlyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    /// Characters produced by special keys → their named token form.
    private static let specialCharsToToken: [String: String] = [
        "\t": "tab",
        "\r": "return",
        " ": "space",
        "\u{1b}": "escape",
    ]

    /// Normalize an NSEvent's key to a token string.
    ///
    /// Priority:
    /// 1. Special chars (tab, return, space, escape)
    /// 2. Single printable ASCII that is itself a known key token → use as-is
    ///    (handles letters, digits, unshifted symbols — correct for Colemak/AZERTY)
    /// 3. Printable but NOT a known key token (e.g. `<`, `?`, `!` from shifted
    ///    symbols) → fall back to `keyCodeToBaseToken` to recover the base key
    /// 4. Empty chars → arrow/non-character keys by keyCode
    static func eventToken(_ event: NSEvent) -> String? {
        guard let chars = event.charactersIgnoringModifiers else {
            return Self.keyCodeToBaseToken[event.keyCode]
        }

        // Special named keys
        if let token = specialCharsToToken[chars] { return token }

        // Single printable ASCII
        if chars.count == 1, let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value < 0x7F
        {
            let lower = chars.lowercased()
            // If the char itself is a known key token, use it directly.
            // This is the correct path for letters (layout-independent),
            // digits, and unshifted symbols.
            if keyCodes[lower] != nil { return lower }
            // Printable but not a known token (e.g. "<" from shift+, "?")
            // → fall back to the keyCode → base-token mapping.
            if let token = Self.keyCodeToBaseToken[event.keyCode] { return token }
            return nil
        }

        // Empty or multi-char → try named non-character keys by position
        return Self.keyCodeToBaseToken[event.keyCode]
    }

    static func parseShortcut(_ raw: String) -> HotkeyShortcut? {
        let cleaned = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty || cleaned == "none" || cleaned == "disabled" {
            return nil
        }

        let tokens = cleaned.split(separator: "+").map(String.init)
        guard let keyToken = tokens.last, let keyCode = keyCodes[keyToken] else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd",
                 "command",
                 "⌘": modifiers.insert(.command)
            case "ctrl",
                 "control",
                 "⌃": modifiers.insert(.control)
            case "shift",
                 "⇧": modifiers.insert(.shift)
            case "opt",
                 "option",
                 "alt",
                 "⌥": modifiers.insert(.option)
            default: return nil
            }
        }

        return HotkeyShortcut(id: cleaned, keyCode: keyCode, keyToken: keyToken, modifiers: modifiers)
    }

    static func shortcutString(from event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierOnlyCodes.contains(event.keyCode) { return nil }

        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("opt") }
        guard !parts.isEmpty else { return nil }

        guard let keyToken = eventToken(event) else { return nil }
        guard keyCodes[keyToken] != nil else { return nil }
        parts.append(keyToken)
        return parts.joined(separator: "+")
    }

    static func displayString(for shortcut: String) -> String {
        let cleaned = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty || cleaned == "disabled" || cleaned == "none" {
            return "Disabled"
        }

        let tokens = cleaned.split(separator: "+").map(String.init)
        guard !tokens.isEmpty else { return "Disabled" }

        var out = ""
        for token in tokens.dropLast() {
            switch token {
            case "cmd",
                 "command": out += "⌘"
            case "ctrl",
                 "control": out += "⌃"
            case "shift": out += "⇧"
            case "opt",
                 "option",
                 "alt": out += "⌥"
            default: break
            }
        }

        let key = tokens.last ?? ""
        let keyLabel: String = switch key {
        case "tab": "Tab"
        case "space": "Space"
        case "return",
             "enter": "↩"
        case "escape": "Esc"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        default: key.uppercased()
        }
        return out + keyLabel
    }

    static func selectedShortcutString(for action: HotkeyAction) -> String {
        UserDefaults.standard.string(forKey: action.defaultsKey) ?? action.defaultShortcut
    }

    static func selectedShortcut(for action: HotkeyAction) -> HotkeyShortcut? {
        parseShortcut(selectedShortcutString(for: action)) ?? parseShortcut(action.defaultShortcut)
    }

    static func setShortcutString(_ shortcut: String, for action: HotkeyAction) {
        UserDefaults.standard.set(shortcut, forKey: action.defaultsKey)
    }

    static func isValidShortcutString(_ shortcut: String) -> Bool {
        let cleaned = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty || cleaned == "none" || cleaned == "disabled" {
            return true
        }
        return parseShortcut(cleaned) != nil
    }

    static func matches(_ event: NSEvent, action: HotkeyAction) -> Bool {
        guard let shortcut = selectedShortcut(for: action), shortcut.id != "none" else { return false }
        return shortcut.matches(event)
    }
}
