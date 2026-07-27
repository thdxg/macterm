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
        let title = titleOverride ?? command.title
        Button(title) {
            action?()
        }
        .disabled(action == nil)
        .modifier(KeyboardShortcutForCommand(command: command))
        // Record the rendered title so `HotkeyMenuSync` can find this item's
        // NSMenuItem later. Registering the same string that titles the Button
        // is what keeps the two from drifting — a `titleOverride` added at a
        // call site can't silently orphan the sync.
        .task {
            if let hotkeyAction = command.hotkeyAction {
                HotkeyMenuSync.register(title: title, action: hotkeyAction)
            }
        }
    }
}

/// Applies the command's keyboard shortcut as it stands *at launch*.
///
/// This only ever runs when SwiftUI builds the menu, which happens once —
/// a `.commands` tree is not re-evaluated from observable state the way an
/// ordinary view body is. Keeping a rebind in sync is therefore not possible
/// here; `HotkeyMenuSync` patches the live `NSMenuItem`s instead. Setting the
/// shortcut here still matters: it's what gives the item its correct initial
/// key equivalent before any rebind happens.
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
