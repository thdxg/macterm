import AppKit
@testable import Macterm
import Testing

@MainActor
struct KeybindPassthroughTests {
    private func makePane(projectPath: String = "/tmp") -> Pane {
        Pane(projectPath: projectPath, projectID: UUID())
    }

    /// `ctrl+h` — the chord the whole feature exists for.
    private func ctrlH() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{08}",
            charactersIgnoringModifiers: "h",
            isARepeat: false,
            keyCode: 4
        ))
    }

    /// Restore the flag so a later test's `passthroughActions()` — a cached,
    /// process-wide read — doesn't inherit this one's state.
    private func withPassthrough(_ action: HotkeyAction, _ body: () throws -> Void) rethrows {
        HotkeyRegistry.setPassesThroughToPrograms(true, for: action)
        defer { HotkeyRegistry.setPassesThroughToPrograms(false, for: action) }
        try body()
    }

    /// All four combinations of the two facts. Only "a real program holds the
    /// foreground AND it has taken the tty raw" yields.
    private func yields(_ pane: Pane?, program: Bool, raw: Bool) -> Bool {
        KeybindPassthrough.yields(
            action: .focusPaneLeft,
            pane: pane,
            foregroundIsProgram: { _ in program },
            inputIsRaw: { _ in raw }
        )
    }

    @Test
    func unflagged_action_never_yields_even_under_a_full_screen_program() {
        #expect(!yields(makePane(), program: true, raw: true))
    }

    @Test
    func flagged_action_yields_only_for_a_program_that_took_the_keyboard() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(yields(pane, program: true, raw: true))
        }
    }

    /// The bug this pairing exists for. An interactive shell runs its own line
    /// editor (ZLE, readline, reedline), which clears `ICANON`/`ECHO` — so an
    /// idle prompt looks raw, and a raw-only condition made every flagged
    /// binding yield everywhere and never fire its action.
    @Test
    func idle_shell_prompt_does_not_yield_despite_a_raw_tty() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(pane, program: false, raw: true))
        }
    }

    /// A plain canonical command holds the foreground without taking over the
    /// keyboard, so pane navigation keeps working while it runs.
    @Test
    func canonical_command_does_not_yield() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(pane, program: true, raw: false))
        }
    }

    @Test
    func no_pane_never_yields() {
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(nil, program: true, raw: true))
        }
    }

    /// A remote pane's local tty belongs to the `ssh -t` client, which holds it
    /// raw for the whole session, and no local pid describes what runs inside
    /// the pane — so both probes mislead and the binding would yield forever.
    /// The guard must reject before probing, not weigh the answers.
    @Test
    func remote_pane_never_yields_and_is_not_even_probed() {
        let remote = makePane(projectPath: "user@host:/srv/app")
        #expect(remote.isRemote)
        var probed = false
        withPassthrough(.focusPaneLeft) {
            let yielded = KeybindPassthrough.yields(
                action: .focusPaneLeft,
                pane: remote,
                foregroundIsProgram: { _ in
                    probed = true
                    return true
                },
                inputIsRaw: { _ in
                    probed = true
                    return true
                }
            )
            #expect(!yielded)
        }
        #expect(!probed)
    }

    /// The hot-path guarantee: with nothing flagged the gate must not scan (and
    /// so must not `eventToken`-normalize) any action — it runs on every
    /// keystroke typed into a terminal.
    @Test
    func matched_action_is_nil_when_nothing_is_flagged() throws {
        let event = try ctrlH()
        #expect(HotkeyRegistry.passthroughActions().isEmpty)
        #expect(KeybindPassthrough.matchedAction(for: event) == nil)
    }

    @Test
    func matched_action_finds_a_flagged_binding_by_its_chord() throws {
        let event = try ctrlH()
        HotkeyRegistry.setShortcutString("ctrl+h", for: .focusPaneLeft)
        defer { HotkeyRegistry.setShortcutString(HotkeyAction.focusPaneLeft.defaultShortcut, for: .focusPaneLeft) }

        // Flagged but bound elsewhere: the chord must not match it.
        try withPassthrough(.focusPaneRight) {
            #expect(KeybindPassthrough.matchedAction(for: event) == nil)
        }

        try withPassthrough(.focusPaneLeft) {
            #expect(HotkeyRegistry.passthroughActions() == [.focusPaneLeft])
            #expect(KeybindPassthrough.matchedAction(for: event) == .focusPaneLeft)
        }
    }

    @Test
    func flagging_invalidates_the_cached_action_list() {
        #expect(HotkeyRegistry.passthroughActions().isEmpty)
        withPassthrough(.zoomPane) {
            #expect(HotkeyRegistry.passthroughActions() == [.zoomPane])
        }
        #expect(HotkeyRegistry.passthroughActions().isEmpty)
    }
}
