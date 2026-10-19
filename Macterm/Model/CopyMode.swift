import Foundation

/// The keymap a pane's copy mode reads its keys with. Helix is the first.
/// A Vim case joins it as a Settings choice; both drive the same selection
/// primitives, since Vim normal mode is Helix normal mode with the anchor
/// always on the head.
enum CopyModeKeymap: String, CaseIterable, Identifiable {
    case helix

    var id: String { rawValue }
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
    var pending: Pending = .none

    enum Pending: Equatable {
        case none
        /// A `g` is down; the next key picks the goto motion.
        case prefixG
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
    /// The motions, by their `SelectionMotion` name in the fork patch.
    private enum Motion: String {
        case left
        case right
        case up
        case down
        case wordNext = "word_next"
        case wordEnd = "word_end"
        case wordPrev = "word_prev"
        case lineStart = "line_start"
        case lineEnd = "line_end"
        case pageUp = "page_up"
        case pageDown = "page_down"
        case halfPageUp = "half_page_up"
        case halfPageDown = "half_page_down"
        case top, bottom

        var isWord: Bool {
            switch self {
            case .wordNext,
                 .wordEnd,
                 .wordPrev: true
            default: false
            }
        }
    }

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// The largest count a prefix can build; more digits are dropped.
    static let maximumCount = 999

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
                 .prefixG:
                // A leading 0 is no count: Helix has no motion on it either.
                if digit > 0 { state.pending = .count(digit) }
            }
            return []
        }

        let named: Motion? = switch key.keyCode {
        case KeyCode.left: .left
        case KeyCode.right: .right
        case KeyCode.up: .up
        case KeyCode.down: .down
        case KeyCode.pageUp: .pageUp
        case KeyCode.pageDown: .pageDown
        case KeyCode.home: .lineStart
        case KeyCode.end: .lineEnd
        default: nil
        }
        if let named { return commands(for: named, state: &state) }

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
        case "x": return repeated([.binding("select_line")], state: &state)
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
        return repeated(once, state: &state)
    }

    private static func repeated(_ once: [CopyModeCommand], state: inout CopyModeState) -> [CopyModeCommand] {
        let count: Int = if case let .count(count) = state.pending { count } else { 1 }
        state.pending = .none
        return Array([[CopyModeCommand]](repeating: once, count: count).joined())
    }
}
