import AppKit

/// Decides whether a matched keybind should be handed to the program running in
/// a pane instead of firing its action — the "smart pane navigation" contract
/// from #209, where `ctrl+h` moves Macterm panes at a shell prompt but reaches
/// nvim so it can move its own splits (and call `macterm pane focus
/// --direction` when it runs out of them).
///
/// Two conditions, both the user's to set: the action is flagged to pass
/// through, and the pane's foreground process is one the user **named**
/// (Settings → Keymaps → Programs). Nothing is inferred about what a program is
/// or wants.
///
/// The name list replaced a tty-mode heuristic, and the failure is worth
/// recording. Raw/cbreak mode looks like it means "a full-screen program is
/// reading keys directly", but interactive shells put the tty in raw mode
/// themselves to run their line editors — zsh's ZLE, bash's readline and
/// nushell's reedline all clear `ICANON`/`ECHO` while reading a line — so an
/// idle prompt was indistinguishable from an editor and a flagged binding
/// yielded everywhere, never firing its action at all. Adding a
/// "foreground is not a shell" test fixed that, but the result was still blunt
/// in the other direction: every raw-mode program yielded, including ones that
/// ignore the chord (`btop`, `less`), which silently swallowed it. An explicit
/// list is the mechanism tmux, kitty, wezterm and zellij all landed on, and it
/// is the only one that can be *right* rather than merely defensible — Macterm
/// cannot know which chords a program wants, but the user does.
///
/// There is no way to do better by *sending* the key first and reacting if the
/// program ignores it: no terminal protocol has a reverse channel for
/// "unhandled", the one screen change that proves nvim moved is the cursor
/// position (which the libghostty ABI can't read), and the send is
/// irreversible — a speculative `ctrl+h` that turns out to be unhandled has
/// already deleted a character in insert mode.
@MainActor
enum KeybindPassthrough {
    /// The user's program list, normalized for matching.
    ///
    /// Separators are commas AND whitespace, so `nvim, hx` and `nvim hx` both
    /// work — there is no reason to make someone's first attempt fail on
    /// punctuation. Entries are lowercased basenames, so a pasted
    /// `/opt/homebrew/bin/nvim` matches the `nvim` the process table reports.
    static func programNames(from raw: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)
        return Set(
            raw.components(separatedBy: separators)
                .map(normalized)
                .filter { !$0.isEmpty }
        )
    }

    /// Lowercased basename, so both sides of the comparison agree whether the
    /// user typed a bare name or a path.
    private static func normalized(_ name: String) -> String {
        ((name as NSString).lastPathComponent as String).lowercased()
    }

    /// Whether `action`'s chord should go to `pane`'s program instead of firing.
    ///
    /// The two lookups are injected so the policy is testable without a live
    /// pty or a preferences round-trip.
    ///
    /// Order is chosen for cost, cheapest first: the per-action flag is a
    /// cached defaults read and the list is a string split, while resolving the
    /// foreground process name is syscalls. An empty list short-circuits before
    /// any of that, so the default configuration never probes a pane.
    ///
    /// `foregroundName` is `runningProcessName`, which is deliberately the SAME
    /// function that names the tab: whatever the tab shows is what the user
    /// types into the list. It reports the shell's own name at an idle prompt,
    /// so a prompt only yields if the user explicitly lists their shell.
    static func yields(
        action: HotkeyAction,
        pane: Pane?,
        programs: () -> Set<String> = { programNames(from: Preferences.shared.passthroughPrograms) },
        foregroundName: (Pane) -> String? = { ProcessInspector.runningProcessName(forPane: $0) }
    ) -> Bool {
        guard HotkeyRegistry.passesThroughToPrograms(for: action) else { return false }
        let listed = programs()
        guard !listed.isEmpty else { return false }
        guard let pane else { return false }
        // A remote pane can't answer this: the only local process is the `ssh`
        // client, so `runningProcessName` reports nothing about what runs on
        // the host. The remote naming pipeline could answer it, but only from a
        // cache refreshed every ~3s that freezes on probe failure — too stale
        // to decide a keystroke, and wrong in the direction that strands the
        // user inside an editor. Guarded explicitly rather than relying on the
        // nil name, so this reasoning survives the pipeline changing.
        guard !pane.isRemote else { return false }
        guard let name = foregroundName(pane) else { return false }
        return listed.contains(normalized(name))
    }

    /// The flagged action whose chord `event` matches, or nil — the gate the
    /// key responders run before their action branches.
    ///
    /// Scans only the flagged actions (see `HotkeyRegistry.passthroughActions`),
    /// so an unflagged configuration costs one `isEmpty` check per keystroke.
    static func matchedAction(for event: NSEvent) -> HotkeyAction? {
        let flagged = HotkeyRegistry.passthroughActions()
        guard !flagged.isEmpty else { return nil }
        return flagged.first { HotkeyRegistry.matches(event, action: $0) }
    }

    /// Combined gate for a responder: true when `event` matches a flagged
    /// action and `pane` is running a program the user listed.
    static func yields(event: NSEvent, pane: Pane?) -> Bool {
        guard let action = matchedAction(for: event) else { return false }
        return yields(action: action, pane: pane)
    }
}
