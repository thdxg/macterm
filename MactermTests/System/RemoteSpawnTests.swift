import Foundation
@testable import Macterm
import Testing

struct RemoteSpawnTests {
    private let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")

    // MARK: - Pane command

    @Test
    func pane_command_execs_zmx_after_guarding_zmx_and_cd() {
        // The remote side is `sh -c '<script>'` with a single-quote-free
        // script — the one form every login shell (bash/zsh/fish/nu)
        // tokenizes identically before POSIX sh takes over.
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        // Missing zmx / bad cwd must NOT close the pane — they drop into a
        // login shell with a diagnostic instead of exiting.
        #expect(cmd?.contains("command -v zmx") == true)
        #expect(cmd?.contains("zmx not found in PATH") == true)
        #expect(cmd?.contains("cannot cd to") == true)
        #expect(cmd?.contains("exec ${SHELL:-/bin/sh}") == true)
        // Happy path still execs the attach into the declared dir.
        #expect(cmd?.contains("cd ~/\"dev/api\"") == true)
        #expect(cmd?.contains("exec zmx attach \"macterm-api-abc123\"") == true)
    }

    @Test
    func pane_command_with_explicit_zmx_path_skips_the_presence_guard() {
        // An explicit path is used verbatim and needs no `command -v` guard —
        // its own failure surfaces as zmx's error, still visible in the pane.
        let cmd = RemoteSpawn.paneCommand(
            remote: remote, sessionName: "macterm-api-abc123", zmxPath: "~/bin/zmx"
        )
        #expect(cmd?.contains("command -v zmx") == false)
        #expect(cmd?.contains("exec \"~/bin/zmx\" attach \"macterm-api-abc123\"") == true)
    }

    @Test
    func pane_command_settles_term_against_the_hosts_own_terminfo() {
        // A resolvable TERM is never touched — the outer test is negated, so
        // the replacement only runs when the arriving TERM has no entry. That
        // precedence matters: preferring xterm-ghostty whenever the host had it
        // overrode a user's `SetEnv TERM=xterm-256color` pin and turned a stock
        // Debian prompt monochrome, since its ~/.bashrc gates color on
        // `xterm-color|*-256color` — a string match no capability check can
        // satisfy. Verified against a stubbed `infocmp` across all five cases.
        //
        // Decided host-side on purpose: `ghostty +ssh` forces
        // `-o SetEnv=TERM=xterm-ghostty` from the client because its wrapper has
        // no remote-side script; ours reads the remote DB directly, so it needs
        // no cache and works where env requests are dropped.
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123") ?? ""
        #expect(cmd.contains("if ! infocmp \"$TERM\" >/dev/null 2>&1; then "))
        #expect(cmd.contains("if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty;"))
        #expect(cmd.contains("else TERM=xterm-256color; fi; export TERM; fi;"))
        // Nested `if`, never `&&`/`||` chaining — the chained form's
        // left-to-right precedence binds the else-branch wrong.
        #expect(!RemoteSpawn.remoteTermPreamble.contains("||"))
        // Pane-only: a background op has no terminal to describe.
        let op = RemoteSpawn.opArgv(remote: remote, zmxArguments: ["ls"])?.joined(separator: " ") ?? ""
        #expect(!op.contains("infocmp"))
    }

    @Test
    func pane_command_declares_truecolor_host_side() {
        // A remote pane's surface is libghostty, so 24-bit color is a fact,
        // but nothing carries it across ssh on its own: TERM rides the pty
        // request while everything else is an env request the server filters
        // (a Tailscale SSH host dropped SendEnv AND SetEnv COLORTERM even with
        // AcceptEnv COLORTERM effective). So the script asserts it itself.
        // Without this, helix refuses a truecolor theme ("theme requires true
        // color support") on any host where TERM isn't xterm-ghostty — which
        // `remoteTermPreamble` can't fix, since it only ever downgrades.
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        #expect(cmd?.contains("COLORTERM=truecolor; export COLORTERM;") == true)
        // Pane-only: background ops and the naming probe render nothing.
        let op = RemoteSpawn.opArgv(remote: remote, zmxArguments: ["ls"])?.joined(separator: " ") ?? ""
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        #expect(!op.contains("COLORTERM"))
        #expect(!probe.contains("COLORTERM"))
    }

    // MARK: - Orphan sweep (#281)

    @Test
    func orphan_sweep_stamps_only_the_names_passed_then_lists() {
        // The safety property: the stamp half can only ever touch sessions
        // OUR panes claim, so it can never brand another machine's session.
        let script = RemoteSpawn.orphanSweepScript(
            sessionNames: ["macterm-api-aa11", "macterm-api-bb22"],
            ownerID: "cafe01",
            zmxPath: nil
        )
        #expect(script.contains("for n in \"macterm-api-aa11\" \"macterm-api-bb22\""))
        #expect(script.contains("zmx set \"$n\" \"macterm.owner=cafe01\""))
        // A session that died between listing and stamping must not fail the
        // sweep, and stamp chatter must not pollute the parsed listing.
        #expect(script.contains(">/dev/null 2>&1 || true"))
        #expect(script.hasSuffix("zmx ls"))
        #expect(!script.contains("'"))
    }

    @Test
    func orphan_sweep_with_no_claimed_names_just_lists() {
        let script = RemoteSpawn.orphanSweepScript(sessionNames: [], ownerID: "cafe01", zmxPath: nil)
        #expect(!script.contains("for n in"))
        #expect(!script.contains("zmx set"))
        #expect(script.hasSuffix("zmx ls"))
    }

    @Test
    func orphan_sweep_argv_uses_the_background_ssh_profile() {
        // BatchMode + ConnectTimeout: a background op can never answer a
        // prompt, so it must fail fast instead of hanging on one.
        let argv = RemoteSpawn.orphanSweepArgv(
            remote: remote, zmxPath: "~/bin/zmx",
            sessionNames: ["macterm-api-aa11"], ownerID: "cafe01"
        )
        let wire = argv?.joined(separator: " ") ?? ""
        #expect(wire.contains("BatchMode=yes"))
        #expect(wire.contains("ConnectTimeout=5"))
        // Explicit zmxPath is used verbatim for both the stamp and the list.
        #expect(wire.contains("\"~/bin/zmx\" set"))
        #expect(wire.contains("\"~/bin/zmx\" ls"))
        #expect(RemoteSpawn.orphanSweepArgv(
            remote: .local("/a"), zmxPath: nil, sessionNames: [], ownerID: "x"
        ) == nil)
    }

    @Test
    func remote_scripts_never_source_profiles() {
        // Locked-in decision (#104): profiles are arbitrary code in the
        // pane's critical path. Sourcing them — inline, in a subshell, or
        // with stdin detached — produced three distinct pane-killers on real
        // hosts (exec hijack of our fds, tty-stdin read-block, profile
        // exec-loop spin). PATH comes from the fallback dir list; anything
        // else is the project's explicit zmxPath.
        let pane = RemoteSpawn.paneCommand(remote: remote, sessionName: "s") ?? ""
        let op = RemoteSpawn.opArgv(remote: remote, zmxArguments: ["ls"])?.joined(separator: " ") ?? ""
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        let sweep = RemoteSpawn.orphanSweepArgv(
            remote: remote, zmxPath: nil, sessionNames: ["macterm-a-1"], ownerID: "x"
        )?.joined(separator: " ") ?? ""
        for wire in [pane, op, probe, sweep] {
            #expect(!wire.contains(".profile"))
            #expect(!wire.contains("/etc/profile"))
        }
    }

    @Test
    func pane_command_script_is_single_quote_free() {
        // Single quotes in the script would break the `sh -c '<script>'`
        // wrapper on a non-POSIX login shell.
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        // The only single quotes are the two that wrap the sh -c argument
        // (the outer ssh quoting escapes them as '\'').
        #expect(cmd?.contains("'\\''") == true)
    }

    @Test
    func pane_command_includes_user_in_destination() {
        let cmd = RemoteSpawn.paneCommand(
            remote: .remote(user: "deploy", host: "10.0.0.5", directory: "/srv/app"),
            sessionName: "macterm-app-ff00"
        )
        #expect(cmd?.contains("ssh -t 'deploy@10.0.0.5'") == true)
        #expect(cmd?.contains("cd \"/srv/app\"") == true)
    }

    @Test
    func pane_command_has_no_batchmode_so_auth_can_prompt() {
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        #expect(cmd?.contains("BatchMode") == false)
    }

    @Test
    func pane_command_is_nil_for_local_paths() {
        #expect(RemoteSpawn.paneCommand(remote: .local("/a/b"), sessionName: "s") == nil)
    }

    // MARK: - Background op argv

    @Test
    func op_argv_uses_batchmode_and_connect_timeout() {
        let argv = RemoteSpawn.opArgv(remote: remote, zmxArguments: ["kill", "macterm-api-abc123"])
        #expect(argv == [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "devbox",
            "\(RemoteSpawn.remoteShell) " + RemoteSpawn.shellQuote(
                RemoteSpawn.remoteEnvPreamble + "exec zmx \"kill\" \"macterm-api-abc123\""
            ),
        ])
        // sh -c (NOT sh -lc): the login flag is unportable — older dash rejects
        // it and drops to an interactive shell.
        #expect(RemoteSpawn.remoteShell == "sh -c")
    }

    @Test
    func op_argv_uses_explicit_zmx_path_verbatim() {
        let argv = RemoteSpawn.opArgv(
            remote: remote, zmxArguments: ["kill", "s"], zmxPath: "~/bin/zmx"
        )
        #expect(argv?.last?.contains("exec \"~/bin/zmx\" \"kill\" \"s\"") == true)
    }

    @Test
    func op_argv_is_nil_for_local_paths() {
        #expect(RemoteSpawn.opArgv(remote: .local("/a"), zmxArguments: ["ls"]) == nil)
    }

    // MARK: - Foreground probe

    @Test
    func probe_argv_is_noninteractive_and_carries_the_script() {
        let argv = RemoteSpawn.foregroundProbeArgv(remote: remote)
        #expect(argv?.prefix(4) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        #expect(argv?.dropFirst(4).first == "devbox")
        let expectedScript = RemoteSpawn.remoteEnvPreamble
            + RemoteSpawn.foregroundProbeScript.replacingOccurrences(of: "<ZMX>", with: "zmx")
        #expect(argv?.last == "\(RemoteSpawn.remoteShell) " + RemoteSpawn.shellQuote(expectedScript))
        #expect(RemoteSpawn.foregroundProbeScript.contains("tpgid"))
        // The host-side idle verdict needs the leader's own pgid to compare
        // against the tty's foreground group.
        #expect(RemoteSpawn.foregroundProbeScript.contains("pgid"))
        // The full command line rides along for layout `run:` capture.
        #expect(RemoteSpawn.foregroundProbeScript.contains("ps -o args="))
        // The sh -c wrapper only survives arbitrary login shells while the
        // script stays free of single quotes.
        #expect(!RemoteSpawn.foregroundProbeScript.contains("'"))
        #expect(RemoteSpawn.foregroundProbeArgv(remote: .local("/a")) == nil)
    }

    @Test
    func probe_argv_substitutes_explicit_zmx_path() {
        let argv = RemoteSpawn.foregroundProbeArgv(remote: remote, zmxPath: "/opt/zmx")
        #expect(argv?.last?.contains("\"/opt/zmx\" ls") == true)
    }

    // MARK: - Quoting

    @Test
    func shell_quote_survives_spaces_dollars_and_quotes() {
        #expect(RemoteSpawn.shellQuote("plain") == "'plain'")
        #expect(RemoteSpawn.shellQuote("with space") == "'with space'")
        #expect(RemoteSpawn.shellQuote("$HOME") == "'$HOME'")
        #expect(RemoteSpawn.shellQuote("it's") == "'it'\\''s'")
    }

    @Test
    func remote_directory_keeps_tilde_expandable() {
        // A quoted tilde is a literal directory named "~" — the tilde segment
        // must stay bare so sh expands it. Double quotes, so the containing
        // sh -c script stays single-quote-free.
        #expect(RemoteSpawn.quoteRemoteDirectory("~") == "~")
        #expect(RemoteSpawn.quoteRemoteDirectory("~/dev/api") == "~/\"dev/api\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~/dir with space") == "~/\"dir with space\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~deploy/app") == "~deploy/\"app\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~deploy") == "~deploy")
    }

    @Test
    func remote_directory_quotes_plain_paths_whole() {
        #expect(RemoteSpawn.quoteRemoteDirectory("/srv/my app") == "\"/srv/my app\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("work/api") == "\"work/api\"")
    }

    // MARK: - Security: tilde-segment injection (§5.3)

    @Test
    func remote_directory_never_ships_a_command_substitution_unquoted() {
        // Only a literal `~` or a `[A-Za-z0-9._-]` username may stay bare. A
        // tilde segment carrying `$(...)`, backticks, or spaces is NOT expandable
        // config — it's an injection vector — so the WHOLE string is
        // double-quoted (escaping `$`/backtick), never emitted raw into the `cd`.
        #expect(RemoteSpawn.quoteRemoteDirectory("~$(touch /tmp/pwned)/sub") == "\"~\\$(touch /tmp/pwned)/sub\"")
        // Slashless form must also be quoted (was previously returned verbatim).
        #expect(RemoteSpawn.quoteRemoteDirectory("~$(id)") == "\"~\\$(id)\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~`id`") == "\"~\\`id\\`\"")
        // A username with a space is not a valid bare-safe name → fully quoted.
        #expect(RemoteSpawn.quoteRemoteDirectory("~evil user/app") == "\"~evil user/app\"")
    }

    @Test
    func remote_directory_bare_forms_produce_no_shell_metacharacters() {
        // Every bare (unquoted) result must be free of shell-active characters,
        // so nothing a tilde path can carry reaches `sh` unquoted.
        for input in ["~", "~/dev/api", "~deploy/app", "~$(cmd)/x", "~a b/c", "/abs/$x"] {
            let quoted = RemoteSpawn.quoteRemoteDirectory(input)
            // Strip the double-quoted spans; whatever remains bare must be inert.
            let bareParts = quoted.split(separator: "\"", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
            #expect(!bareParts.contains("$"), "bare `$` leaked for \(input): \(quoted)")
            #expect(!bareParts.contains("`"), "bare backtick leaked for \(input): \(quoted)")
            #expect(!bareParts.contains(" "), "bare space leaked for \(input): \(quoted)")
        }
    }

    // MARK: - Security: single-quote-free wire invariant (§5.4)

    @Test
    func assert_single_quote_free_passes_clean_scripts_through() {
        let clean = "PATH=$PATH; exec \"zmx\" attach \"macterm-x-abc\""
        #expect(RemoteSpawn.assertSingleQuoteFree(clean) == clean)
    }

    @Test
    func assert_single_quote_free_replaces_a_script_carrying_a_single_quote() {
        // A `'` in a user-controlled field (project dir / zmxPath) would, once
        // wrapped by `shellQuote`, become `'\''` — which fish/nu tokenize
        // differently than POSIX sh, the exact breakage the invariant prevents.
        // Such a script is swapped for a diagnostic that is itself quote-free.
        let dirty = "cd \"~/it's-a-dir\"; exec zmx"
        let result = RemoteSpawn.assertSingleQuoteFree(dirty)
        #expect(result != dirty)
        #expect(!result.contains("'"))
        #expect(result.contains("unsupported single quote"))
        #expect(result.contains("exec ${SHELL:-/bin/sh}"))
    }

    @Test
    func assert_single_quote_free_op_path_exits_nonzero_not_a_shell() {
        // A kill/probe (background op) with a `'`-carrying path must FAIL
        // honestly (exit 1), not drop into an interactive shell that exits 0 —
        // otherwise killRemoteSession would report a silent no-op success.
        let dirty = "exec zmx kill \"it's\""
        let result = RemoteSpawn.assertSingleQuoteFree(dirty, onViolation: .failNonZero)
        #expect(!result.contains("'"))
        #expect(result.contains("unsupported single quote"))
        #expect(result.contains("exit 1"))
        #expect(!result.contains("exec ${SHELL")) // no interactive shell on the op path
    }

    @Test
    func pane_command_with_single_quote_in_directory_stays_quote_free() {
        // End-to-end: a `'` in the remote directory must not survive into the
        // shipped `sh -c '<script>'` (its `'` would break the outer quoting).
        let remoteWithQuote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/it's")
        let cmd = RemoteSpawn.paneCommand(remote: remoteWithQuote, sessionName: "macterm-x-abc123")
        // The script body (between the outer single quotes) carries no attach —
        // it was replaced by the quote-free diagnostic.
        #expect(cmd?.contains("unsupported single quote") == true)
        #expect(cmd?.contains("exec zmx attach") == false)
    }

    @Test
    func op_argv_with_single_quote_in_zmx_path_stays_quote_free() {
        let cmd = RemoteSpawn.opArgv(
            remote: remote, zmxArguments: ["kill", "macterm-x-abc123"], zmxPath: "~/it's/zmx"
        )
        let script = try? #require(cmd?.last)
        #expect(script?.contains("unsupported single quote") == true)
        #expect(script?.contains("kill") == false)
    }

    @Test
    func posix_double_quote_escapes_shell_metacharacters() {
        #expect(RemoteSpawn.posixDoubleQuote("plain") == "\"plain\"")
        #expect(RemoteSpawn.posixDoubleQuote("a$b") == "\"a\\$b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a\"b") == "\"a\\\"b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a`b") == "\"a\\`b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a\\b") == "\"a\\\\b\"")
    }

    // MARK: - Destination

    @Test
    func destination_composes_user_and_host() {
        #expect(RemoteSpawn.destination(user: nil, host: "devbox") == "devbox")
        #expect(RemoteSpawn.destination(user: "me", host: "devbox") == "me@devbox")
    }
}
