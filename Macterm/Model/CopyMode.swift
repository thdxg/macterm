import Foundation

/// The keymap a pane's copy mode reads its keys with: Helix or Vim
/// (Settings → Keymaps → Copy Mode). Both drive the same selection
/// primitives of the fork: the terminal's selection is the cursor, its end
/// the head and its start the anchor.
enum CopyModeKeymap: String, CaseIterable, Identifiable, PreferenceValue {
    case helix
    case vim

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .helix: "Helix"
        case .vim: "Vim"
        }
    }

    /// The title of the pane's pill for a state under this keymap.
    func label(for state: CopyModeState) -> String {
        switch self {
        case .helix:
            if state.selectMode {
                String(localized: "Select Mode", comment: "Pill on a pane in Helix copy mode")
            } else {
                String(localized: "Copy Mode", comment: "Pill on a pane in copy mode")
            }
        case .vim:
            switch state.visual {
            case .none: String(localized: "Copy Mode", comment: "Pill on a pane in copy mode")
            case .char: String(localized: "Visual", comment: "Pill on a pane in Vim visual mode")
            case .line: String(localized: "Visual Line", comment: "Pill on a pane in Vim visual line mode")
            case .block: String(localized: "Visual Block", comment: "Pill on a pane in Vim visual block mode")
            }
        }
    }
}

/// One key press, with no AppKit in it. The view builds it from an
/// `NSEvent`; `sendKey` builds it from a key code and modifiers for
/// `pane key`, so the CLI drives the mode the way the keyboard does.
struct CopyModeKey: Equatable {
    /// What the key types (`NSEvent.characters`, "" for none). A control
    /// chord carries its control character (⌃U is U+0015); a shifted symbol
    /// its symbol (`%`).
    var characters: String
    /// The key without Option (`NSEvent.charactersIgnoringModifiers`): the
    /// letter of a chord, upper case under Shift.
    var charactersIgnoringModifiers: String
    var keyCode: UInt16
    var command = false
    var control = false
    var option = false
    var shift = false
}

/// What the mode keeps between keys. The position is not here: the
/// terminal's selection is the cursor (its end the head, its start the
/// anchor).
struct CopyModeState: Equatable {
    /// Helix select mode (`v`): motions keep the anchor.
    var selectMode = false
    /// Vim visual mode (`v`, `V`, `⌃v`): motions keep the anchor, and the
    /// line and block modes shape the selection after each one.
    var visual: Visual = .none
    var pending: Pending = .none

    enum Visual: Equatable {
        case none
        case char
        case line
        case block
    }

    enum Pending: Equatable {
        case none
        /// A `g` is down; the next key picks the goto motion.
        case prefixG
        /// A `y` is down in Vim normal mode; a second `y` yanks the line.
        case prefixY
        /// A count is being typed; it repeats the next motion.
        case count(Int)
    }
}

/// What a key resolves to. `binding` is a libghostty keybind action string,
/// run on the surface as it is (`move_selection:left`, `copy_to_clipboard`).
enum CopyModeCommand: Equatable {
    case binding(String)
    case selectMode(Bool)
    case exit
}

/// The motions, by their `SelectionMotion` name in the fork patches.
enum CopyModeMotion: String {
    case left
    case right
    case up
    case down
    case wordNext = "word_next"
    case wordEnd = "word_end"
    case wordPrev = "word_prev"
    case nextWordStart = "next_word_start"
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case pageUp = "page_up"
    case pageDown = "page_down"
    case halfPageUp = "half_page_up"
    case halfPageDown = "half_page_down"
    case top
    case bottom

    var isWord: Bool {
        switch self {
        case .wordNext,
             .wordEnd,
             .wordPrev,
             .nextWordStart: true
        default: false
        }
    }
}

/// The key codes of the named keys both keymaps read.
enum CopyModeKeyCode {
    static let escape: UInt16 = 53
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let end: UInt16 = 119
    static let pageDown: UInt16 = 121
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    /// The motion of a named key, nil for any other key.
    static func motion(for keyCode: UInt16) -> CopyModeMotion? {
        switch keyCode {
        case left: .left
        case right: .right
        case up: .up
        case down: .down
        case pageUp: .pageUp
        case pageDown: .pageDown
        case home: .lineStart
        case end: .lineEnd
        default: nil
        }
    }
}

/// The count prefix both keymaps share.
enum CopyModeCount {
    /// The largest count a prefix can build; more digits are dropped.
    static let maximum = 999

    /// `once`, repeated by the pending count, which this consumes.
    static func repeated(_ once: [CopyModeCommand], state: inout CopyModeState) -> [CopyModeCommand] {
        let count: Int = if case let .count(count) = state.pending { count } else { 1 }
        state.pending = .none
        return Array([[CopyModeCommand]](repeating: once, count: count).joined())
    }
}

/// The Helix keymap of the copy mode. Pure: `resolve` reads one key, updates
/// the state, and says what to run.
///
/// Normal mode moves the head and puts the anchor on it (`move_selection`);
/// select mode keeps the anchor (`extend_selection`). The word motions `w`,
/// `e` and `b` select the range they move over in normal mode too, as in
/// Helix, so they collapse first and then extend. A count repeats a motion.
/// `g` waits for one more key. Escape clears a pending prefix first, then
/// leaves select mode, and only then leaves the mode.
///
/// Letters are matched by their unshifted character and the Shift flag, so
/// Dvorak and Colemak get their own letters. Symbols are matched by what
/// they type. Every ⌘ chord is nil: not this keymap's, and the caller lets
/// it flow as usual (⌘C copies the selection). Any other key that is not in
/// the table is swallowed, so nothing types into the shell while the mode is
/// on.
enum HelixKeymap {
    private typealias Motion = CopyModeMotion
    private typealias KeyCode = CopyModeKeyCode

    /// The largest count a prefix can build; more digits are dropped.
    static let maximumCount = CopyModeCount.maximum

    /// nil = not this keymap's key (every ⌘ chord): the caller lets it flow
    /// as usual. [] = swallowed (an unbound key types nothing while the mode
    /// is on).
    static func resolve(_ key: CopyModeKey, state: inout CopyModeState) -> [CopyModeCommand]? {
        if key.command { return nil }

        if key.keyCode == KeyCode.escape {
            if state.pending != .none {
                state.pending = .none
                return []
            }
            if state.selectMode {
                state.selectMode = false
                return [.selectMode(false)]
            }
            return [.exit]
        }

        let letter = key.charactersIgnoringModifiers.lowercased()

        if key.control {
            let motion: Motion? = switch letter {
            case "u": .halfPageUp
            case "d": .halfPageDown
            case "b": .pageUp
            case "f": .pageDown
            default: nil
            }
            guard let motion else {
                state.pending = .none
                return []
            }
            return commands(for: motion, state: &state)
        }

        if case .prefixG = state.pending {
            state.pending = .none
            let motion: Motion? = if key.option {
                nil
            } else {
                switch letter {
                case "g": .top
                case "e": .bottom
                case "h": .lineStart
                case "l": .lineEnd
                default: nil
                }
            }
            guard let motion else { return [] }
            return commands(for: motion, state: &state)
        }

        if !key.option, letter.count == 1, let digit = Int(letter) {
            switch state.pending {
            case let .count(count):
                state.pending = .count(min(count * 10 + digit, maximumCount))
            case .none,
                 .prefixG,
                 .prefixY:
                // A leading 0 is no count: Helix has no motion on it either.
                if digit > 0 { state.pending = .count(digit) }
            }
            return []
        }

        if let named = KeyCode.motion(for: key.keyCode) { return commands(for: named, state: &state) }

        if key.option {
            if letter == ";" {
                state.pending = .none
                return [.binding("flip_selection")]
            }
            state.pending = .none
            return []
        }

        switch letter {
        case "h": return commands(for: .left, state: &state)
        case "j": return commands(for: .down, state: &state)
        case "k": return commands(for: .up, state: &state)
        case "l": return commands(for: .right, state: &state)
        case "w": return commands(for: .wordNext, state: &state)
        case "e": return commands(for: .wordEnd, state: &state)
        case "b": return commands(for: .wordPrev, state: &state)
        case "x": return CopyModeCount.repeated([.binding("select_line")], state: &state)
        case "g":
            state.pending = .prefixG
            return []
        case "v":
            state.pending = .none
            state.selectMode.toggle()
            return [.selectMode(state.selectMode)]
        case "y":
            state.pending = .none
            return [.binding("copy_to_clipboard"), .exit]
        case "n":
            state.pending = .none
            return [.binding(key.shift ? "navigate_search:previous" : "navigate_search:next")]
        default: break
        }

        switch key.characters {
        case ";":
            state.pending = .none
            return [.binding("collapse_selection")]
        case "%":
            state.pending = .none
            return [.binding("select_all")]
        case "/":
            state.pending = .none
            return [.binding("start_search")]
        default:
            state.pending = .none
            return []
        }
    }

    /// The commands of one motion, repeated by the pending count.
    private static func commands(for motion: Motion, state: inout CopyModeState) -> [CopyModeCommand] {
        let extend: CopyModeCommand = .binding("extend_selection:\(motion.rawValue)")
        let once: [CopyModeCommand] = if state.selectMode {
            [extend]
        } else if motion.isWord {
            [.binding("collapse_selection"), extend]
        } else {
            [.binding("move_selection:\(motion.rawValue)")]
        }
        return CopyModeCount.repeated(once, state: &state)
    }
}

/// The Vim keymap of the copy mode, as the vi copy mode of tmux and the vi
/// mode of Alacritty read it. Pure, as `HelixKeymap`.
///
/// Normal mode moves the head and puts the anchor on it. `v` starts visual
/// mode, where motions keep the anchor; `V` is visual line mode, where the
/// selection grows to whole rows after each motion (`select_line_bounds`,
/// which keeps the direction, so `Vk` keeps moving the head up); `⌃v` is
/// visual block mode (`selection_rectangle`). The same key again, or Escape,
/// leaves visual mode and collapses the selection to the head. `y` in
/// visual mode copies and leaves the mode; `yy` and `Y` copy the line; `q`
/// leaves the mode. `w` lands on the start of the next word
/// (`next_word_start`), where Helix lands before it. `0`, `^`, `$`, `gg`
/// and `G` are the line and screen motions. A count repeats a motion; a
/// bare `0` is a motion, not a count.
enum VimKeymap {
    private typealias Motion = CopyModeMotion
    private typealias KeyCode = CopyModeKeyCode

    /// The largest count a prefix can build; more digits are dropped.
    static let maximumCount = CopyModeCount.maximum

    /// nil = not this keymap's key (every ⌘ chord). [] = swallowed.
    static func resolve(_ key: CopyModeKey, state: inout CopyModeState) -> [CopyModeCommand]? {
        if key.command { return nil }

        if key.keyCode == KeyCode.escape {
            if state.pending != .none {
                state.pending = .none
                return []
            }
            if state.visual != .none { return leaveVisual(&state) }
            return [.exit]
        }

        let letter = key.charactersIgnoringModifiers.lowercased()

        if key.control {
            switch letter {
            case "u": return commands(for: .halfPageUp, state: &state)
            case "d": return commands(for: .halfPageDown, state: &state)
            case "b": return commands(for: .pageUp, state: &state)
            case "f": return commands(for: .pageDown, state: &state)
            case "v": return toggleVisual(.block, state: &state)
            default:
                state.pending = .none
                return []
            }
        }

        switch state.pending {
        case .prefixG:
            state.pending = .none
            if !key.option, letter == "g" { return commands(for: .top, state: &state) }
            return []
        case .prefixY:
            state.pending = .none
            if !key.option, letter == "y" { return yankLine() }
            return []
        case .none,
             .count:
            break
        }

        if !key.option, letter.count == 1, let digit = Int(letter) {
            switch state.pending {
            case let .count(count):
                state.pending = .count(min(count * 10 + digit, maximumCount))
                return []
            case .none,
                 .prefixG,
                 .prefixY:
                if digit > 0 {
                    state.pending = .count(digit)
                    return []
                }
                // A bare 0 is the start of the line.
                return commands(for: .lineStart, state: &state)
            }
        }

        if let named = KeyCode.motion(for: key.keyCode) { return commands(for: named, state: &state) }

        if key.option {
            state.pending = .none
            return []
        }

        switch letter {
        case "h": return commands(for: .left, state: &state)
        case "j": return commands(for: .down, state: &state)
        case "k": return commands(for: .up, state: &state)
        case "l": return commands(for: .right, state: &state)
        case "w": return commands(for: .nextWordStart, state: &state)
        case "e": return commands(for: .wordEnd, state: &state)
        case "b": return commands(for: .wordPrev, state: &state)
        case "g":
            if key.shift { return commands(for: .bottom, state: &state) }
            state.pending = .prefixG
            return []
        case "v": return toggleVisual(key.shift ? .line : .char, state: &state)
        case "o":
            state.pending = .none
            return state.visual == .none ? [] : [.binding("flip_selection")]
        case "y":
            state.pending = .none
            if key.shift { return yankLine() }
            if state.visual != .none { return [.binding("copy_to_clipboard"), .exit] }
            state.pending = .prefixY
            return []
        case "q":
            state.pending = .none
            return [.exit]
        case "n":
            state.pending = .none
            return [.binding(key.shift ? "navigate_search:previous" : "navigate_search:next")]
        default: break
        }

        switch key.characters {
        case "$": return commands(for: .lineEnd, state: &state)
        case "^": return commands(for: .lineStart, state: &state)
        case "/":
            state.pending = .none
            return [.binding("start_search")]
        default:
            state.pending = .none
            return []
        }
    }

    /// The commands of one motion, repeated by the pending count. Visual
    /// line mode shapes the selection again after each motion.
    private static func commands(for motion: Motion, state: inout CopyModeState) -> [CopyModeCommand] {
        let once: [CopyModeCommand] = switch state.visual {
        case .none: [.binding("move_selection:\(motion.rawValue)")]
        case .char,
             .block: [.binding("extend_selection:\(motion.rawValue)")]
        case .line: [.binding("extend_selection:\(motion.rawValue)"), .binding("select_line_bounds")]
        }
        return CopyModeCount.repeated(once, state: &state)
    }

    /// Enter a visual mode, switch to it from another, or leave it with
    /// its own key again.
    private static func toggleVisual(_ mode: CopyModeState.Visual, state: inout CopyModeState) -> [CopyModeCommand] {
        state.pending = .none
        if state.visual == mode { return leaveVisual(&state) }
        var commands: [CopyModeCommand] = state.visual == .block ? [.binding("selection_rectangle:off")] : []
        state.visual = mode
        switch mode {
        case .line: commands.append(.binding("select_line_bounds"))
        case .block: commands.append(.binding("selection_rectangle:on"))
        case .char,
             .none: break
        }
        return commands
    }

    /// Back to normal mode: the selection collapses to the head, and a
    /// block selection is a line selection again first.
    private static func leaveVisual(_ state: inout CopyModeState) -> [CopyModeCommand] {
        var commands: [CopyModeCommand] = state.visual == .block ? [.binding("selection_rectangle:off")] : []
        state.visual = .none
        commands.append(.binding("collapse_selection"))
        return commands
    }

    /// `yy` and `Y`: the whole line of the head, copied, and the mode ends.
    private static func yankLine() -> [CopyModeCommand] {
        [.binding("select_line_bounds"), .binding("copy_to_clipboard"), .exit]
    }
}
