import Foundation

/// The short tutorials `macterm tutor <topic>` prints — plain terminal output,
/// so a first-run pane can teach with scrollback the user can read, re-run or
/// clear instead of chrome that has to be dismissed. Seeded into a fresh
/// install's panes as their `run:` (see `FirstRunSeed`).
///
/// **Rendered in the app, not in the CLI**, which is the whole reason `tutor`
/// is a control-socket verb rather than an offline one like `ssh`: the
/// shortcut columns come from `HotkeyRegistry` — the user's LIVE bindings,
/// overrides included — and only the app has them. Duplicating the default
/// table into the CLI would have printed `⌘T` at someone who rebound it.
///
/// The chord grid is therefore laid out from the resolved strings rather than
/// hand-aligned: columns are padded to whatever the bindings actually are,
/// and an action the user has unbound drops out of the grid rather than
/// printing a blank cell.
///
/// Not actor-isolated: everything it reads is either pure (`HotkeyRegistry`'s
/// grammar) or the `nonisolated` defaults domain, so `FirstRunSeed` can name
/// a `Topic` without dragging the main actor into a plain value type.
enum Tutorial {
    /// Wire vocabulary: these strings appear verbatim in the seeded `run:`
    /// declarations and in `pinned.yaml`, so renaming a case is a persisted-
    /// declaration change, not a refactor.
    enum Topic: String, CaseIterable {
        /// A project tab: what projects are, and the keys/CLI to work them.
        case project
        /// A pinned tab: what the row above the projects is for.
        case pinned
    }

    /// How a `HotkeyAction` becomes a display chord. Defaults to the user's
    /// live binding; injected in tests.
    typealias ShortcutResolver = (HotkeyAction) -> String

    /// A function, not a stored closure: a `static let` holding a closure is
    /// not `Sendable` under strict concurrency.
    ///
    /// `displaySymbols`, not `displayString`: the latter renders an unbound
    /// action as the literal "None", which the grid would happily print as a
    /// chord ("None  pin this tab"). An empty string is this file's signal
    /// for "leave the row out".
    static func liveShortcut(_ action: HotkeyAction) -> String {
        HotkeyRegistry.displaySymbols(for: HotkeyRegistry.selectedShortcutString(for: action)).joined()
    }

    static func render(
        topic: Topic,
        styled: Bool,
        shortcut: ShortcutResolver = liveShortcut
    ) -> String {
        let style = Style(enabled: styled)
        return switch topic {
        case .project: project(style, shortcut)
        case .pinned: pinned(style, shortcut)
        }
    }

    // MARK: - Topics

    private static func project(_ s: Style, _ shortcut: ShortcutResolver) -> String {
        let grid = keyGrid([
            (.newTab, "new tab"),
            (.splitRight, "split right"),
            (.toggleCommandPalette, "command palette"),
            (.openProject, "open a folder"),
            (.splitDown, "split down"),
            (.toggleSidebar, "toggle sidebar"),
            (.renameTab, "rename tab"),
            (.zoomPane, "zoom a pane"),
            (.toggleQuickTerminal, "quick terminal"),
        ], style: s, shortcut: shortcut)

        let focus = chordList(
            [.focusPaneLeft, .focusPaneDown, .focusPaneUp, .focusPaneRight],
            style: s,
            shortcut: shortcut
        )

        var lines = [
            "",
            "  " + s.bold("Macterm — the basics"),
            "",
            s.dim("""
              You're in a project tab. Projects are the folders in the sidebar; each
              keeps its own tabs and splits, and its shells stay alive in the
              background — still running when you come back, even after a restart.
            """),
            "",
        ]
        lines += grid
        if !grid.isEmpty { lines.append("") }
        if let focus {
            lines.append(s.dim("  Move focus between panes with ") + focus + s.dim("."))
            lines.append("")
        }
        lines += [
            s.dim("  Every pane can also drive the app it lives in:"),
            "",
            "    " + s.accent("macterm pane split") + s.dim("   split this pane"),
            "    " + s.accent("macterm grid 2x2") + s.dim("     four panes, one command"),
            "    " + s.accent("macterm --help") + s.dim("       everything else"),
            "",
            s.dim("  Above the projects is a pinned tab — open ") + s.bold("Welcome")
                + s.dim(" for the rest"),
            s.dim("  of the tour. This is just terminal output: type ") + s.accent("clear")
                + s.dim(" to dismiss it."),
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func pinned(_ s: Style, _ shortcut: ShortcutResolver) -> String {
        var lines = [
            "",
            "  " + s.bold("Pinned tabs"),
            "",
            s.dim("""
              This tab belongs to no project. It sits above them in the sidebar and
              stays put while you switch projects — good for a scratch shell, a log
              tail, or an agent you want to keep running.
            """),
            "",
            s.dim("  · Pin any tab: right-click its sidebar row → ") + s.bold("Pin Tab")
                + s.dim(", or drag it"),
            s.dim("    onto the strip above the projects."),
            s.dim("  · Closing a pinned tab keeps the row. It reloads — re-running"),
            s.dim("    whatever command it was running — the next time you select it."),
            s.dim("  · The set is a file you can edit:"),
            "    " + s.accent("~/.config/macterm/projects/pinned.yaml"),
            s.dim("  · Done with this one? Right-click the row → ") + s.bold("Unpin Tab")
                + s.dim("."),
            "",
        ]
        // Both pin actions ship unbound, so this pair usually prints nothing —
        // it appears only for a user who has given them chords.
        let pinChords = keyGrid([
            (.pinTab, "pin this tab"),
            (.unpinTab, "unpin this tab"),
        ], style: s, shortcut: shortcut)
        if !pinChords.isEmpty {
            lines += pinChords
            lines.append("")
        }
        lines += [
            s.dim("  Settings (") + s.accent("⌘,") + s.dim(") → Keymaps rebinds every shortcut."),
            s.dim("  Docs: ") + s.accent("https://macterm.thdxg.dev/docs/"),
            "",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Layout

    /// A 3-column chord grid, padded to the resolved bindings' own widths.
    /// Unbound actions are dropped (never a blank cell), so the grid can come
    /// back short — or empty, if the user has unbound the lot.
    private static func keyGrid(
        _ entries: [(HotkeyAction, String)],
        style s: Style,
        shortcut: ShortcutResolver,
        columns: Int = 3
    ) -> [String] {
        let cells = entries.compactMap { action, label -> (String, String)? in
            let chord = shortcut(action)
            return chord.isEmpty ? nil : (chord, label)
        }
        guard !cells.isEmpty else { return [] }
        let chordWidth = cells.map(\.0.count).max() ?? 0
        let labelWidth = cells.map(\.1.count).max() ?? 0
        return stride(from: 0, to: cells.count, by: columns).map { start in
            let row = cells[start ..< min(start + columns, cells.count)]
            let rendered = row.enumerated().map { index, cell -> String in
                let isLast = start + index == cells.count - 1 || index == row.count - 1
                let chord = s.accent(pad(cell.0, to: chordWidth))
                // Only interior cells pay for the label padding; padding the
                // last one would leave trailing whitespace on every line.
                let label = isLast ? cell.1 : pad(cell.1, to: labelWidth + 2)
                return chord + "  " + s.dim(label)
            }
            return "    " + rendered.joined()
        }
    }

    /// The bound chords of a related set, space-separated (`⌘⌃H ⌘⌃J …`) — for
    /// the directional actions, where four labelled grid cells would say the
    /// same thing four times. nil when none of them is bound.
    private static func chordList(
        _ actions: [HotkeyAction],
        style s: Style,
        shortcut: ShortcutResolver
    ) -> String? {
        let chords = actions.map(shortcut).filter { !$0.isEmpty }
        guard !chords.isEmpty else { return nil }
        return s.accent(chords.joined(separator: " "))
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// ANSI wrapper. `enabled` is the CLI's `isatty(1)` verdict, passed over
    /// the wire — the app can't see the CLI's stdout.
    private struct Style {
        let enabled: Bool

        func bold(_ text: String) -> String {
            wrap(text, "\u{1B}[1m")
        }

        func dim(_ text: String) -> String {
            wrap(text, "\u{1B}[2m")
        }

        func accent(_ text: String) -> String {
            wrap(text, "\u{1B}[36m")
        }

        private func wrap(_ text: String, _ code: String) -> String {
            enabled ? code + text + "\u{1B}[0m" : text
        }
    }
}
