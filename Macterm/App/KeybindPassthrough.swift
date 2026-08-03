import AppKit

/// Decides whether a matched keybind should be handed to the program running in
/// a pane instead of firing its action — the "smart pane navigation" contract
/// from #209, where `ctrl+h` moves Macterm panes at a shell prompt but reaches
/// nvim so it can move its own splits (and call `macterm pane focus
/// --direction` when it runs out of them).
///
/// The condition is two facts about the pane, NOT a list of program names:
/// a real program (not a shell) holds the foreground, AND the tty is in
/// raw/cbreak mode. Both are needed.
///
/// Raw mode alone is WRONG, which cost a round trip to learn: interactive
/// shells put the tty in raw mode themselves to run their own line editors —
/// zsh's ZLE, bash's readline, nushell's reedline all clear `ICANON`/`ECHO`
/// while reading a line — so an idle prompt reads exactly like a full-screen
/// editor and a flagged binding yielded unconditionally, never firing its
/// action anywhere. The foreground-process test is what separates them, and it
/// stays name-free: `ProcessInspector` recognizes *shells* from the host's own
/// database (`getusershell`, the login shell, `$SHELL`), which is the opposite
/// of an allowlist of programs Macterm has heard of.
///
/// Requiring raw mode as well is what keeps a plain canonical command
/// (`sleep 20`, `npm test`) from swallowing the chord — those hold the
/// foreground without ever taking over the keyboard, so pane navigation still
/// works while they run.
///
/// The cost of that generality is bluntness at the edges: a raw-mode program
/// that ignores the chord (`btop`, `less`) swallows it rather than moving
/// panes. That's the deliberate trade — a name list would be precise and
/// permanently incomplete.
///
/// There is no way to do better by *sending* the key first and reacting if the
/// program ignores it: no terminal protocol has a reverse channel for
/// "unhandled", the one screen change that proves nvim moved is the cursor
/// position (which the libghostty ABI can't read), and the send is
/// irreversible — a speculative `ctrl+h` that turns out to be unhandled has
/// already deleted a character in insert mode. So the decision has to be made
/// before delivery, on a heuristic, or delegated to the program itself.
@MainActor
enum KeybindPassthrough {
    /// Whether `action`'s chord should go to `pane`'s program instead of firing.
    ///
    /// Both facts are injected so every combination is testable without a live
    /// pty; the defaults read the pane's real foreground process and tty mode.
    ///
    /// `foregroundIsProgram` is deliberately built on `foregroundProgramPID`,
    /// which answers nil BOTH for an idle shell and for a pane whose foreground
    /// can't be read (a zmx-wrapped pane before the resolver cache warms). That
    /// conflation is the safe one here: unknown means keep the app binding.
    ///
    /// Order matters for cost: the per-action flag is a cached defaults read,
    /// while the two probes are syscalls. Checking the flag first keeps the
    /// default configuration — nothing flagged — free.
    static func yields(
        action: HotkeyAction,
        pane: Pane?,
        foregroundIsProgram: (Pane) -> Bool = { ProcessInspector.foregroundProgramPID(forPane: $0) != nil },
        inputIsRaw: (Pane) -> Bool = { ProcessInspector.terminalInputIsRaw(forPane: $0) }
    ) -> Bool {
        guard HotkeyRegistry.passesThroughToPrograms(for: action) else { return false }
        guard let pane else { return false }
        // A remote pane can never answer this. Its local tty belongs to the
        // `ssh -t` client, which keeps it raw for the whole session, and no
        // local pid describes what runs inside the pane — so both probes
        // mislead and the binding would yield forever, never navigating. Same
        // trap as the zmx attach client's permanently-raw pty, which
        // `terminalInputIsRaw(forPane:)` sidesteps by probing the daemon's tty;
        // there is no equivalent for a host across ssh.
        guard !pane.isRemote else { return false }
        return foregroundIsProgram(pane) && inputIsRaw(pane)
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
    /// action and `pane`'s program should receive it instead.
    static func yields(event: NSEvent, pane: Pane?) -> Bool {
        guard let action = matchedAction(for: event) else { return false }
        return yields(action: action, pane: pane)
    }
}
