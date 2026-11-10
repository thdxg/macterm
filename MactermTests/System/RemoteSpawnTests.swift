import Foundation
@testable import Macterm
import Testing

struct RemoteSpawnTests {
    private let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")

    // MARK: - Pane command

    private let key = "0123abcd"

    private func attach(_ session: String = "macterm-api-abc123") -> String {
        RemoteSpawn.sessionCommand(key: key, sessionName: session, create: nil)
    }

    private func create(_ directory: String = "~/dev/api") -> String {
        RemoteSpawn.sessionCommand(key: key, sessionName: "macterm-api-abc123", create: directory)
    }

    @Test
    func a_pane_runs_the_host_servers_own_client_of_its_session() {
        // The remote side is `sh -c '<script>'` with a single-quote-free
        // script — the one form every login shell (bash/zsh/fish/nu)
        // tokenizes identically before POSIX sh takes over.
        let attach = attach()
        #expect(attach.hasPrefix("sh -c '"))
        #expect(attach.contains("b=\"$HOME/.local/share/macterm/bin/macterm-0123abcd\""))
        #expect(attach.contains("exec \"$b\" connect \"macterm-api-abc123\""))
        // An attach never makes a session: a missing one is an error, never
        // a new shell in silence.
        #expect(!attach.contains(" --"))
        #expect(!attach.contains("cd "))
        // A create goes to the folder, and `--` makes the missing session.
        let create = create()
        #expect(create.contains("cd ~/\"dev/api\""))
        #expect(create.contains("exec \"$b\" connect \"macterm-api-abc123\" --"))
    }

    @Test
    func a_missing_binary_is_a_lost_connection_and_a_bad_folder_still_persists() {
        // A host that lost its files after the check: exit 255 makes the
        // pane wait, and the next connect installs again. A folder that is
        // not there starts the session in the home folder, so it persists.
        #expect(attach().contains("[ -x \"$b\" ] || exit 255"))
        let create = create()
        #expect(create.contains("cannot cd to"))
        #expect(create.contains(">&2; cd; }"))
    }

    @Test
    func a_plain_shell_is_a_login_shell_in_the_folder() {
        let plain = RemoteSpawn.plainShellCommand(directory: "~/dev/api")
        #expect(plain.hasPrefix("sh -c '"))
        #expect(plain.contains("cd ~/\"dev/api\""))
        #expect(plain.contains("if [ -n \"$SHELL\" ]; then exec \"$SHELL\" -l; else exec /bin/sh; fi"))
        #expect(!plain.contains("connect"))
        #expect(!plain.contains("ZMX_FOREGROUND_EVENTS"))
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
        for cmd in [attach(), RemoteSpawn.plainShellCommand(directory: "~")] {
            #expect(cmd.contains("if ! infocmp \"$TERM\" >/dev/null 2>&1; then "))
            #expect(cmd.contains("if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty;"))
            #expect(cmd.contains("else TERM=xterm-256color; fi; export TERM; fi;"))
        }
        // Nested `if`, never `&&`/`||` chaining — the chained form's
        // left-to-right precedence binds the else-branch wrong.
        #expect(!RemoteSpawn.remoteTermPreamble.contains("||"))
        // Pane-only: a background op has no terminal to describe.
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        #expect(!probe.contains("infocmp"))
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
        #expect(attach().contains("COLORTERM=truecolor; export COLORTERM;"))
        #expect(RemoteSpawn.plainShellCommand(directory: "~").contains("COLORTERM=truecolor; export COLORTERM;"))
        // Pane-only: background ops and the naming probe render nothing.
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        #expect(!probe.contains("COLORTERM"))
    }

    @Test
    func pane_command_declares_the_terminal_program_host_side() {
        // Claude Code sends OSC 9;4 progress — the agent's busy/done dot —
        // only to TERM_PROGRAM=ghostty at 1.2.0 or later, and ssh carries
        // neither variable on its own.
        #expect(attach().contains(RemoteSpawn.remoteTerminalProgramPreamble))
        #expect(RemoteSpawn.remoteTerminalProgramPreamble.hasPrefix("TERM_PROGRAM=ghostty; export TERM_PROGRAM; "))
        let preamble = RemoteSpawn.terminalProgramPreamble(version: "1.3.2-main+b368389")
        #expect(preamble.contains("TERM_PROGRAM_VERSION=1.3.2-main+b368389; export TERM_PROGRAM_VERSION;"))
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        #expect(!probe.contains("TERM_PROGRAM"))
    }

    @Test
    func pane_command_asks_the_host_for_foreground_reports() throws {
        // The client reads the variable (`ZmxForegroundEvents`) and removes
        // it before the session starts. Background operations never attach,
        // so they carry nothing.
        let cmd = attach()
        #expect(cmd.contains("ZMX_FOREGROUND_EVENTS=1; export ZMX_FOREGROUND_EVENTS; "))
        #expect(try #require(cmd.range(of: "ZMX_FOREGROUND_EVENTS")?.lowerBound) < cmd.range(of: "connect")!.lowerBound)
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        #expect(!probe.contains("ZMX_FOREGROUND_EVENTS"))
    }

    @Test
    func terminal_program_preamble_drops_a_version_that_is_not_plain() {
        for version in [nil, "", "1.3; rm -rf ~", "1.3 beta", "1.3\"", "$(id)"] {
            let preamble = RemoteSpawn.terminalProgramPreamble(version: version)
            #expect(preamble == "TERM_PROGRAM=ghostty; export TERM_PROGRAM; ")
        }
    }

    @Test
    func remote_scripts_never_source_profiles() {
        // Locked-in decision (#104): profiles are arbitrary code in the
        // pane's critical path. Sourcing them — inline, in a subshell, or
        // with stdin detached — produced three distinct pane-killers on real
        // hosts (exec hijack of our fds, tty-stdin read-block, profile
        // exec-loop spin). PATH comes from the fallback dir list; anything
        // else is the project's explicit zmxPath.
        let probe = RemoteSpawn.foregroundProbeArgv(remote: remote)?.joined(separator: " ") ?? ""
        for wire in [attach(), create(), RemoteSpawn.plainShellCommand(directory: "~"), probe] {
            #expect(!wire.contains(".profile"))
            #expect(!wire.contains("/etc/profile"))
        }
    }

    @Test
    func pane_command_script_is_single_quote_free() {
        // Single quotes in the script would break the `sh -c '<script>'`
        // wrapper on a non-POSIX login shell: the only two wrap it.
        for cmd in [attach(), create(), RemoteSpawn.plainShellCommand(directory: "/srv/app")] {
            #expect(cmd.count { $0 == "'" } == 2)
        }
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
        // The shell verdict is the host's own /etc/shells, not the Mac's.
        #expect(RemoteSpawn.foregroundProbeScript.contains("done < /etc/shells"))
        #expect(RemoteSpawn.foregroundProbeScript.contains("tmux|screen|zellij) ;;"))
        // The sh -c wrapper only survives arbitrary login shells while the
        // script stays free of single quotes.
        #expect(!RemoteSpawn.foregroundProbeScript.contains("'"))
        #expect(RemoteSpawn.foregroundProbeArgv(remote: .local("/a")) == nil)
        // sh -c (NOT sh -lc): the login flag is unportable — older dash rejects
        // it and drops to an interactive shell.
        #expect(RemoteSpawn.remoteShell == "sh -c")
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
        // A background op (the probe) with a `'`-carrying path must FAIL
        // honestly (exit 1), not drop into an interactive shell that exits 0 —
        // otherwise it would report a silent no-op success.
        let dirty = "exec zmx ls \"it's\""
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
        // The pane gets the diagnostic and a shell, never a silent close.
        for cmd in [create("~/it's"), RemoteSpawn.plainShellCommand(directory: "~/it's")] {
            #expect(cmd.contains("unsupported single quote"))
            #expect(!cmd.contains("connect"))
            #expect(cmd.count { $0 == "'" } == 2)
        }
    }

    @Test
    func probe_argv_with_single_quote_in_zmx_path_stays_quote_free() {
        let script = RemoteSpawn.foregroundProbeArgv(remote: remote, zmxPath: "~/it's/zmx")?.last
        #expect(script?.contains("unsupported single quote") == true)
        #expect(script?.contains(" ls") == false)
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

    // MARK: - Git probe

    @Test
    func git_probe_runs_the_five_reads_in_one_connection() throws {
        let argv = try #require(RemoteSpawn.gitProbeArgv(remote: remote))
        #expect(argv.contains("BatchMode=yes"))
        #expect(argv.contains("devbox"))
        let command = try #require(argv.last)
        #expect(command.hasPrefix("sh -c '"))
        let script = String(command.dropFirst("sh -c '".count).dropLast())
        // The wire-format invariant: no single quote inside the script.
        #expect(!script.contains("'"))
        #expect(script.contains("cd ~/\"dev/api\" 2>/dev/null || exit 2"))
        #expect(script.contains("command -v git >/dev/null 2>&1 || exit 3"))
        #expect(script.contains("status --porcelain=v2 --branch --show-stash 2>/dev/null || exit 4"))
        #expect(script.contains("log -5 --format=%h%x1f%s%x1f%ct"))
        #expect(script.contains("for-each-ref refs/heads --sort=-committerdate --count=6"))
        #expect(script.contains("worktree list --porcelain"))
        #expect(script.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(script.contains("{ " + ProjectGit.branchLogScript(git: "git -c core.fsmonitor=false -c core.quotePath=false --no-pager")))
        // A detached HEAD has no branch log, and that is not a failure.
        #expect(script.hasSuffix("; } 2>/dev/null; exit 0"))
        #expect(script.components(separatedBy: "printf \"\\036\"").count == 5)
        // A git on the host's PATH only; profiles are never sourced.
        #expect(!script.contains("profile"))
    }

    @Test
    func git_probe_is_nil_for_a_local_path_and_fails_closed_on_a_single_quote() throws {
        #expect(RemoteSpawn.gitProbeArgv(remote: .local("/tmp")) == nil)
        let argv = try #require(RemoteSpawn.gitProbeArgv(remote: .remote(user: nil, host: "devbox", directory: "/it's")))
        #expect(argv.last?.contains("exit 1") == true)
        #expect(argv.last?.contains("git") == false)
    }
}
