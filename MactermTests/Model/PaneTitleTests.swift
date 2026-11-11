import Foundation
@testable import Macterm
import Testing

/// Tests for the pane's title model: the OSC-title provenance gate
/// (`receiveReportedTitle`) and its expiry (`applyForegroundRefresh`).
/// Both are exercised through their testable cores, with the foreground
/// pid / program-pid lookups passed in instead of read from live surfaces.
@MainActor
struct PaneTitleTests {
    private func makePane() -> Pane {
        Pane(projectPath: "/", projectID: UUID())
    }

    // MARK: - receiveReportedTitle (provenance gate)

    @Test
    func title_from_program_is_adopted() {
        let pane = makePane()
        pane.receiveReportedTitle("✳ Fix tab switcher", programPID: 42)
        #expect(pane.programTitle == "✳ Fix tab switcher")
        #expect(pane.displayTitle == "✳ Fix tab switcher")
    }

    @Test
    func title_from_shell_prompt_is_ignored() {
        let pane = makePane()
        // programPID nil = the foreground process is the shell (prompt churn).
        pane.receiveReportedTitle("~/dev/macterm", programPID: nil)
        #expect(pane.programTitle == nil)
    }

    @Test
    func blank_title_is_ignored() {
        let pane = makePane()
        pane.receiveReportedTitle("   ", programPID: 42)
        #expect(pane.programTitle == nil)
    }

    @Test
    func title_is_trimmed() {
        let pane = makePane()
        pane.receiveReportedTitle("  hello \n", programPID: 42)
        #expect(pane.programTitle == "hello")
    }

    @Test
    func same_program_can_update_its_title() {
        let pane = makePane()
        pane.receiveReportedTitle("first", programPID: 42)
        pane.receiveReportedTitle("second", programPID: 42)
        #expect(pane.programTitle == "second")
    }

    @Test
    func bare_version_title_is_ignored() {
        // Claude Code emits its version (`2.1.202`) as an OSC 2 title at its
        // prompt — useless as a tab name. Discard it so displayTitle falls back
        // to the process name; a real (non-version) title still adopts.
        let pane = makePane()
        pane.receiveReportedTitle("2.1.202", programPID: 42)
        #expect(pane.programTitle == nil)

        pane.receiveReportedTitle("✳ Claude Code", programPID: 42)
        #expect(pane.programTitle == "✳ Claude Code")
    }

    @Test
    func looksLikeVersionString_matches_only_bare_dotted_numbers() {
        #expect(ProcessInspector.looksLikeVersionString("2.1.202"))
        #expect(ProcessInspector.looksLikeVersionString("1.0"))
        #expect(ProcessInspector.looksLikeVersionString("10.20.30.40"))
        // Not versions: no dot, non-numeric, or version embedded in a name.
        #expect(!ProcessInspector.looksLikeVersionString("claude"))
        #expect(!ProcessInspector.looksLikeVersionString("node"))
        #expect(!ProcessInspector.looksLikeVersionString("v2.1.202"))
        #expect(!ProcessInspector.looksLikeVersionString("2.1.202-beta"))
        #expect(!ProcessInspector.looksLikeVersionString("2"))
        #expect(!ProcessInspector.looksLikeVersionString("."))
        #expect(!ProcessInspector.looksLikeVersionString(""))
    }

    // MARK: - applyForegroundRefresh (expiry)

    @Test
    func title_survives_while_its_pid_holds_the_foreground() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: "claude", foregroundPID: 42)
        #expect(pane.programTitle == "session")
    }

    @Test
    func title_expires_when_foreground_returns_to_shell() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: "nu", foregroundPID: 7, foregroundIsShell: true)
        #expect(pane.programTitle == nil)
        // Display falls back to the process name.
        #expect(pane.displayTitle == "nu")
    }

    @Test
    func title_expires_when_a_different_program_takes_over() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        // claude exits and btop starts between two polls: the pid changed,
        // so claude's title must not be attributed to btop. Expiry is
        // immediate — it is keyed on the pid, NOT on the debounced name.
        pane.applyForegroundRefresh(name: "btop", foregroundPID: 43)
        #expect(pane.programTitle == nil)
        #expect(pane.displayTitle == "btop")
    }

    @Test
    func title_expires_when_surface_is_gone() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: nil, foregroundPID: nil)
        #expect(pane.programTitle == nil)
    }

    // MARK: - Prompt-hook debounce (transient foreground processes)

    private func loginShellName() throws -> String {
        try (String(cString: #require(getpwuid(getuid())?.pointee.pw_shell)) as NSString).lastPathComponent
    }

    /// A hook-heavy shell forks `starship`/`mise`/`zoxide` on every prompt.
    /// Publishing one renamed the tab to `starship`, and because the poll stops
    /// while the window is occluded and the app is inactive, that wrong name
    /// stuck until a click or keystroke re-sampled.
    @Test
    func promptHookNeverBecomesTheTabName() throws {
        let pane = makePane()
        let shell = try loginShellName()

        pane.applyForegroundRefresh(name: shell, foregroundPID: 10)
        #expect(pane.foregroundProcessName == shell)

        // The shell reports its command finished, so it is now at a prompt.
        pane.notePromptReturned()

        // A poll lands inside a prompt hook's ~64ms lifetime.
        pane.applyForegroundRefresh(name: "starship", foregroundPID: 11)
        #expect(pane.foregroundProcessName == shell)
        #expect(pane.displayTitle == shell)

        // Another hook, next prompt — still never adopted.
        pane.applyForegroundRefresh(name: "mise", foregroundPID: 12)
        #expect(pane.foregroundProcessName == shell)

        // The shell itself is always allowed through, so no lag returning.
        pane.applyForegroundRefresh(name: shell, foregroundPID: 10)
        #expect(pane.foregroundProcessName == shell)
    }

    /// The gate must not swallow the user's actual command: submitting one
    /// means the shell is no longer at a prompt, so the name lands on the very
    /// first poll — no added latency.
    @Test
    func submittedCommandIsNamedImmediately() throws {
        let pane = makePane()
        let shell = try loginShellName()
        pane.applyForegroundRefresh(name: shell, foregroundPID: 10)
        pane.notePromptReturned()

        pane.recordCommandSubmission(hasContent: true)
        pane.applyForegroundRefresh(name: "hx", foregroundPID: 20)
        #expect(pane.foregroundProcessName == "hx")
    }

    /// A shell with no OSC 133 integration never reports a prompt, so the gate
    /// never arms and naming is exactly as it was before it existed.
    @Test
    func withoutShellIntegration_namingIsUnchanged() {
        let pane = makePane()
        pane.applyForegroundRefresh(name: "npm", foregroundPID: 30)
        #expect(pane.foregroundProcessName == "npm")
        pane.applyForegroundRefresh(name: "node", foregroundPID: 31)
        #expect(pane.foregroundProcessName == "node")
    }

    // MARK: - Remote panes (#104): execution-gated titles, names from the host's reports

    private func makeRemotePane() -> Pane {
        Pane(projectPath: "devbox:~/dev/api", projectID: UUID())
    }

    private let claude = RemoteForeground(comm: "2.1.289", isIdle: false, command: "claude")
    private let zsh = RemoteForeground(comm: "-zsh", isIdle: true, isShell: true, command: "-zsh")

    @Test
    func a_title_in_the_replay_of_an_attach_never_names_the_pane() {
        // After a restart, `top` holds the pty and the replay carries the
        // shell's last title from before `top` started.
        let pane = makeRemotePane()
        pane.receiveUnknownAPC("zmx;foreground;0;0;top;top")
        pane.receiveUnknownAPC(ZmxForegroundEvents.snapshotStart)
        pane.receiveReportedTitle("dev@box: ~/work")
        #expect(pane.programTitle == nil)
        pane.receiveUnknownAPC(ZmxForegroundEvents.snapshotEnd)
        #expect(pane.programTitle == nil)
        #expect(pane.foregroundProcessName == "top")
        // A title after the replay is new output, and counts.
        pane.receiveReportedTitle("top - load")
        #expect(pane.programTitle == "top - load")
    }

    /// A Claude Code turn: typed, running with a progress title, ended.
    private func runTurn(_ pane: Pane, title: String = "◐ Terminal session icons") {
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveRemoteReportedTitle(title)
        pane.markProgressFinished()
    }

    @Test
    func remote_title_is_adopted_only_while_executing() {
        let pane = makeRemotePane()
        // At the prompt with no report: nothing says a program holds the pty.
        pane.receiveRemoteReportedTitle("~/dev/api")
        #expect(pane.programTitle == nil)

        // The tracker gates running on a user interaction (typing the
        // command), same as the real flow.
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveRemoteReportedTitle("✳ remote session")
        #expect(pane.programTitle == "✳ remote session")
    }

    @Test
    func remote_title_expires_when_the_run_ends_at_the_shell() {
        // The shell's report lands before the prompt that ends the run.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveRemoteReportedTitle("✳ remote session")
        pane.applyRemoteForeground(zsh)
        pane.markCommandFinished()
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_title_outlives_a_turn_while_the_agent_holds_the_pty() {
        // No flicker to the process name between turns.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        runTurn(pane)
        #expect(pane.programTitle == "◐ Terminal session icons")
        pane.receiveRemoteReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == "✳ Terminal session icons")
    }

    @Test
    func remote_title_without_a_report_is_kept_only_for_its_run() {
        // A host with no server (a plain shell) reports nothing: a title is
        // shown while its run lasts, and nothing else is.
        let pane = makeRemotePane()
        runTurn(pane)
        #expect(pane.programTitle == nil)
        pane.receiveRemoteReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_title_is_dropped_while_the_shell_holds_the_pty() {
        let pane = makeRemotePane()
        pane.applyRemoteForeground(zsh)
        pane.receiveRemoteReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_report_of_the_shell_clears_an_idle_title() {
        // The agent quits between turns, so no run ends: the report alone
        // settles it.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        pane.receiveRemoteReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == "✳ Terminal session icons")
        pane.applyRemoteForeground(zsh)
        #expect(pane.programTitle == nil)
        pane.receiveRemoteReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_return_clears_the_title_at_once() {
        // OSC 133;D is the host's shell owning its prompt.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        runTurn(pane)
        pane.notePromptReturned()
        #expect(pane.programTitle == nil)
        // A title after it is the prompt's.
        pane.receiveRemoteReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_return_after_the_title_drops_it() {
        // A title hook that runs before ghostty's precmd titles first, then
        // OSC 133;D lands.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        pane.receiveRemoteReportedTitle("~/dev")
        pane.notePromptReturned()
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_title_from_a_nested_shell_is_discarded() {
        // The host says the session's shell doesn't own the tty, but what
        // does is another shell: its prompt titles are churn.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(RemoteForeground(comm: "zsh", isIdle: false, command: "zsh"))
        pane.receiveRemoteReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_multiplexer_is_a_program() {
        // The host never calls tmux a shell (Debian lists it in /etc/shells),
        // so its titles and its `run:` are a program's.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(RemoteForeground(comm: "tmux", isIdle: false, isShell: false, command: "tmux attach"))
        pane.receiveRemoteReportedTitle("build: make")
        #expect(pane.programTitle == "build: make")
        #expect(pane.remoteForegroundCommand == "tmux attach")
    }

    @Test
    func remote_title_from_a_shell_only_the_host_knows_is_discarded() {
        // `elvish` is in the host's /etc/shells and not the Mac's: the host's
        // verdict decides.
        let pane = makeRemotePane()
        pane.applyRemoteForeground(RemoteForeground(comm: "elvish", isIdle: false, isShell: true, command: "elvish"))
        pane.receiveRemoteReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_pane_idle_title_is_the_host() {
        let pane = makeRemotePane()
        #expect(pane.displayTitle == "devbox")
    }

    @Test
    func remote_foreground_name_comes_from_the_report_and_keeps_basename() {
        let pane = makeRemotePane()
        // A macOS remote reports comm as a full path; keep the basename.
        pane.applyRemoteForegroundName("/usr/local/bin/btop")
        #expect(pane.displayTitle == "btop")
        // No name (nil) keeps the last-known name — no title flapping.
        pane.applyRemoteForegroundName(nil)
        #expect(pane.displayTitle == "btop")
    }

    @Test
    func remote_login_shell_dash_is_stripped() {
        // A login shell's argv[0] carries a leading '-' (`-/opt/homebrew/bin/nu`,
        // `-zsh`) — kernel comm never does, so it must be stripped only here.
        #expect(Pane.normalizeRemoteComm("-/opt/homebrew/bin/nu") == "nu")
        #expect(Pane.normalizeRemoteComm("-zsh") == "zsh")
        #expect(Pane.normalizeRemoteComm("/usr/bin/hx") == "hx")
        #expect(Pane.normalizeRemoteComm("btop") == "btop")

        let pane = makeRemotePane()
        pane.applyRemoteForegroundName("-/opt/homebrew/bin/nu")
        #expect(pane.displayTitle == "nu")
    }

    @Test
    func remote_version_named_program_takes_its_invoked_name() {
        // Claude Code's native install sets its comm to its version; locally
        // the executable names it, remotely the command line does.
        #expect(Pane.remoteProcessName(comm: "/x/versions/2.1.207", command: "claude --resume") == "claude")
        #expect(Pane.remoteProcessName(comm: "2.1.207", command: "/Users/me/.local/bin/claude") == "claude")
        #expect(Pane.remoteProcessName(comm: "2.1.207", command: nil) == "2.1.207")
        #expect(Pane.remoteProcessName(comm: "-zsh", command: "-zsh") == "zsh")

        let pane = makeRemotePane()
        pane.applyRemoteForeground(claude)
        #expect(pane.displayTitle == "claude")
    }

    @Test
    func local_pane_is_not_remote() {
        let pane = makePane()
        #expect(!pane.isRemote)
        #expect(pane.remoteHost == nil)
    }

    // MARK: - displayTitle

    @Test
    func displayTitle_falls_back_to_process_name_without_a_program_title() {
        let pane = makePane()
        pane.applyForegroundRefresh(name: "hx", foregroundPID: 9)
        #expect(pane.displayTitle == "hx")
    }

    @Test
    func tab_autoTitle_uses_program_title_for_its_segment() {
        let pane = makePane()
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        pane.receiveReportedTitle("✳ session", programPID: 42)
        #expect(tab.autoTitle == "✳ session")
    }

    // MARK: - Throttle wiring

    /// A flood of reported titles reaches the expensive path twice: once on
    /// the first title, once at the window's end for the newest held one —
    /// counted by the `.terminalPollEvent` that path posts, since without a
    /// surface every title is prompt churn and adopts nothing. The pure
    /// throttle is `TitleReportThrottleTests`; this pins the pane's flush
    /// timer to it.
    @Test
    func a_flood_of_titles_is_evaluated_once_per_window() async {
        let pane = Pane(projectPath: "/", projectID: UUID(), titleReportInterval: 0.05)
        let posts = LockedBox(0)
        let token = NotificationCenter.default.addObserver(
            forName: .terminalPollEvent,
            object: nil,
            queue: nil
        ) { _ in posts.mutate { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        for i in 0 ..< 500 {
            pane.receiveReportedTitle("t\(i)")
        }
        // The leading edge's post is deferred one run-loop turn, the trailing
        // flush lands after the window: poll rather than sleep a fixed multiple
        // (see PaneTests.quietPollWake…).
        for _ in 0 ..< 200 where posts.value < 2 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(posts.value == 2)
        // And nothing else is pending once the flush ran.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(posts.value == 2)
    }
}
