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
    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case recentTab = "recent_tab"
    case openProject = "open_project"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closePane: "Close Pane"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .toggleSidebar: "Toggle Sidebar"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .recentTab: "Last Used Tab"
        case .openProject: "Open Project"
        }
    }

    var defaultsKey: String { "macterm.hotkey.\(rawValue)" }

    var defaultShortcut: String {
        switch self {
        case .newTab: "cmd+t"
        case .closePane: "cmd+w"
        case .splitRight: "cmd+d"
        case .splitDown: "cmd+shift+d"
        case .toggleSidebar: "cmd+b"
        case .nextTab: "cmd+]"
        case .previousTab: "cmd+["
        case .recentTab: "ctrl+tab"
        case .openProject: "cmd+o"
        }
    }
}

struct HotkeyShortcut: Identifiable {
    let id: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
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
    ]
    private static let modifierOnlyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    private static var keyTokensByCode: [UInt16: String] {
        var map: [UInt16: String] = [:]
        for (token, code) in keyCodes where map[code] == nil {
            map[code] = token
        }
        return map
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

        return HotkeyShortcut(id: cleaned, keyCode: keyCode, modifiers: modifiers)
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

        guard let keyToken = keyTokensByCode[event.keyCode] else { return nil }
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
