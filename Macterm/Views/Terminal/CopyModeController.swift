import AppKit

/// The copy mode of one pane: a keyboard cursor over the scrollback, in the
/// Helix model. The terminal's selection is the cursor — its end is the head
/// that the motions move, its start is the anchor — so the mode keeps no
/// position of its own. What it keeps is whether it is on, whether select
/// mode (`v`) is on, and a pending prefix (`g`, a count).
///
/// The keys stay in Macterm, not in a ghostty key table, so a Vim keymap can
/// join the Helix one as a Settings choice, and counts and multi-key
/// sequences work. Each key resolves through the keymap (`HelixKeymap`) to
/// keybind actions that `send` runs on the surface
/// (`ghostty_surface_binding_action`): `move_selection:left`,
/// `extend_selection:word_next`, `select_line`, `copy_to_clipboard` and so
/// on. The selection primitives are fork patch 0013.
@MainActor
final class CopyModeController {
    private(set) var isActive = false
    private(set) var state = CopyModeState()
    var keymap: CopyModeKeymap = .helix

    /// The label the pane's pill shows, nil when the mode is off.
    var onLabelChange: ((String?) -> Void)?

    /// Runs a keybind action on the surface. Injected so a test can drive
    /// the mode without a surface.
    private let send: (String) -> Void

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    var label: String? {
        guard isActive else { return nil }
        return keymap.label(for: state)
    }

    /// Turn the mode on. The selection starts at the terminal cursor, and the
    /// renderer draws the cursor on its head from then on (fork patch 0014),
    /// so the cursor shows there at once and the program's cursor goes away.
    ///
    /// The keymap is the setting (Settings → Keymaps → Copy Mode) unless the
    /// caller names one; the DEBUG verb does, so the e2e suite can drive
    /// both keymaps without a change of the setting.
    func enter(keymap chosen: CopyModeKeymap? = nil) {
        guard !isActive else { return }
        keymap = chosen ?? Preferences.shared.copyModeKeymap
        state = CopyModeState()
        isActive = true
        send("start_selection")
        send("selection_cursor:on")
        publish()
    }

    /// Turn the mode off: the cursor goes back to the program's, and the
    /// selection is cleared.
    func exit() {
        guard isActive else { return }
        isActive = false
        state = CopyModeState()
        send("selection_cursor:off")
        send("clear_selection")
        publish()
    }

    func toggle() {
        if isActive { exit() } else { enter() }
    }

    /// Forget the mode without touching the surface: the surface is going.
    func reset() {
        guard isActive else { return }
        isActive = false
        state = CopyModeState()
        publish()
    }

    /// Handle a key while the mode is on. Returns false when the key is not
    /// the mode's (a ⌘ chord), so the caller handles it as usual.
    func handle(_ key: CopyModeKey) -> Bool {
        guard isActive else { return false }
        let commands: [CopyModeCommand]? = switch keymap {
        case .helix: HelixKeymap.resolve(key, state: &state)
        case .vim: VimKeymap.resolve(key, state: &state)
        }
        guard let commands else { return false }
        for command in commands {
            switch command {
            case let .binding(action):
                send(action)
            case let .selectMode(on):
                state.selectMode = on
            case .exit:
                exit()
                return true
            }
        }
        publish()
        return true
    }

    private func publish() {
        onLabelChange?(label)
    }
}

extension CopyModeKey {
    /// The key of a `keyDown` event.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            command: flags.contains(.command),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift)
        )
    }

    /// The key `pane key` sends: a key code and modifiers, with no event to
    /// read characters from. The characters come from the US layout table
    /// `HotkeyRegistry` keeps, which is also what `sendKey` types.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let base = HotkeyRegistry.printableText(forKeyCode: keyCode, shift: false) ?? ""
        let typed = HotkeyRegistry.printableText(forKeyCode: keyCode, shift: flags.contains(.shift)) ?? ""
        self.init(
            characters: typed,
            charactersIgnoringModifiers: base,
            keyCode: keyCode,
            command: flags.contains(.command),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift)
        )
    }
}
