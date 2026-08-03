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

    /// `list` is what the user typed into Settings → Keymaps → Programs;
    /// `foreground` is what the pane is actually running.
    private func yields(_ pane: Pane?, list: String, foreground: String?) -> Bool {
        KeybindPassthrough.yields(
            action: .focusPaneLeft,
            pane: pane,
            programs: { KeybindPassthrough.programNames(from: list) },
            foregroundName: { _ in foreground }
        )
    }

    @Test
    func unflagged_action_never_yields_even_for_a_listed_program() {
        #expect(!yields(makePane(), list: "nvim", foreground: "nvim"))
    }

    @Test
    func flagged_action_yields_only_to_a_listed_program() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(yields(pane, list: "nvim, hx", foreground: "nvim"))
            #expect(yields(pane, list: "nvim, hx", foreground: "hx"))
            // Running, raw, full-screen — but not something the user named.
            #expect(!yields(pane, list: "nvim, hx", foreground: "btop"))
        }
    }

    /// An empty list is the default, and it must be inert: a ticked checkbox
    /// with nothing named keeps firing the action rather than swallowing the
    /// chord. Checked before the pane is even consulted (see below).
    @Test
    func empty_list_never_yields() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(pane, list: "", foreground: "nvim"))
            #expect(!yields(pane, list: "   ,  , ", foreground: "nvim"))
        }
    }

    /// An empty list must short-circuit before resolving the foreground process,
    /// because that costs syscalls and the gate is on the keystroke path.
    @Test
    func empty_list_does_not_resolve_the_foreground_process() {
        let pane = makePane()
        var resolved = false
        withPassthrough(.focusPaneLeft) {
            _ = KeybindPassthrough.yields(
                action: .focusPaneLeft,
                pane: pane,
                programs: { [] },
                foregroundName: { _ in
                    resolved = true
                    return "nvim"
                }
            )
        }
        #expect(!resolved)
    }

    /// An idle prompt reports the shell's own name, so it can only yield if the
    /// user deliberately listed their shell.
    @Test
    func idle_shell_prompt_does_not_yield_unless_the_shell_is_listed() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(pane, list: "nvim", foreground: "nu"))
            #expect(yields(pane, list: "nvim, nu", foreground: "nu"))
        }
    }

    @Test
    func unreadable_foreground_never_yields() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(pane, list: "nvim", foreground: nil))
        }
    }

    @Test
    func no_pane_never_yields() {
        withPassthrough(.focusPaneLeft) {
            #expect(!yields(nil, list: "nvim", foreground: "nvim"))
        }
    }

    @Test
    func program_names_accept_commas_whitespace_paths_and_case() {
        #expect(KeybindPassthrough.programNames(from: "nvim, hx") == ["nvim", "hx"])
        // Whitespace alone separates too — a first attempt shouldn't fail on
        // missing punctuation.
        #expect(KeybindPassthrough.programNames(from: "nvim hx") == ["nvim", "hx"])
        #expect(KeybindPassthrough.programNames(from: "  nvim ,\n hx,, ") == ["nvim", "hx"])
        // A pasted absolute path matches the bare name the process table gives.
        #expect(KeybindPassthrough.programNames(from: "/opt/homebrew/bin/nvim") == ["nvim"])
        #expect(KeybindPassthrough.programNames(from: "NVIM") == ["nvim"])
        #expect(KeybindPassthrough.programNames(from: "").isEmpty)
    }

    /// Matching normalizes BOTH sides, so a listed path and an upper-case
    /// process name still meet in the middle.
    @Test
    func matching_normalizes_the_foreground_name_too() {
        let pane = makePane()
        withPassthrough(.focusPaneLeft) {
            #expect(yields(pane, list: "nvim", foreground: "/opt/homebrew/bin/nvim"))
            #expect(yields(pane, list: "/opt/homebrew/bin/nvim", foreground: "NVIM"))
        }
    }

    /// No local process describes what runs inside a remote pane, and the
    /// remote naming pipeline is a ~3s cache that freezes on probe failure —
    /// too stale to decide a keystroke. Rejected outright, not probed, so a
    /// later change to that pipeline can't quietly start feeding this.
    @Test
    func remote_pane_never_yields_and_is_not_even_probed() {
        let remote = makePane(projectPath: "user@host:/srv/app")
        #expect(remote.isRemote)
        var probed = false
        withPassthrough(.focusPaneLeft) {
            let yielded = KeybindPassthrough.yields(
                action: .focusPaneLeft,
                pane: remote,
                programs: { ["nvim"] },
                foregroundName: { _ in
                    probed = true
                    return "nvim"
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
