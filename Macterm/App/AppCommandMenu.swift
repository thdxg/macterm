import SwiftUI

/// SwiftUI button for an `AppCommand` in the menu bar. Reuses
/// `AppCommand.action(in:)` so the menu and palette can never drift apart.
/// Disables itself when the command doesn't apply in the current context
/// (e.g. "Next Tab" with no active project).
@MainActor
struct AppCommandMenuItem: View {
    let command: AppCommand
    let appState: AppState
    let projectStore: ProjectStore
    /// Optional title override. Defaults to `command.title` (sentence-cased),
    /// but the menu bar prefers title-cased entries to match macOS standard
    /// menus (e.g. "New Tab" rather than "New tab").
    var titleOverride: String?

    var body: some View {
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
        let action = command.action(in: ctx)
        Button(titleOverride ?? command.title) {
            action?()
        }
        .disabled(action == nil)
        .modifier(KeyboardShortcutForCommand(command: command))
    }
}

/// Reads the current keyboard shortcut for `command` (if any) and applies it
/// to the menu item. Pulls from `HotkeyRegistry`, so a user's rebind in
/// Settings flows through here on the next view rebuild.
private struct KeyboardShortcutForCommand: ViewModifier {
    let command: AppCommand

    func body(content: Content) -> some View {
        if let shortcut = swiftUIShortcut(for: command) {
            content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}

/// Maps Macterm's stringly-typed shortcut (e.g. `cmd+shift+l`) to SwiftUI's
/// `KeyEquivalent` + `EventModifiers`. Returns nil when the command has no
/// hotkey, no current binding, or the binding can't be expressed as a single
/// key (e.g. function keys aren't in Macterm's hotkey grammar yet).
@MainActor
private func swiftUIShortcut(for command: AppCommand) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
    guard let action = command.hotkeyAction else { return nil }
    let raw = HotkeyRegistry.selectedShortcutString(for: action)
    let cleaned = raw.lowercased().replacingOccurrences(of: " ", with: "")
    if cleaned.isEmpty || cleaned == "disabled" || cleaned == "none" { return nil }

    let tokens = cleaned.split(separator: "+").map(String.init)
    guard let keyToken = tokens.last else { return nil }

    var modifiers: EventModifiers = []
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

    let key: KeyEquivalent? = switch keyToken {
    case "return",
         "enter": .return
    case "tab": .tab
    case "space": .space
    case "escape": .escape
    case "delete": .delete
    case "left": .leftArrow
    case "right": .rightArrow
    case "up": .upArrow
    case "down": .downArrow
    default:
        keyToken.count == 1 ? KeyEquivalent(Character(keyToken)) : nil
    }
    guard let key else { return nil }
    return (key, modifiers)
}
