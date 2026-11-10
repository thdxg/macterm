import Foundation

/// Builds the commands behind remote projects (#104). Pure string assembly:
/// every command line is unit-testable without a host.
///
/// Two deliberately different profiles:
/// - **A pane's command** (`sessionCommand`, `plainShellCommand`): it runs
///   on the tty of an ssh channel over the host's one connection
///   (`SSHConnections.ttyArguments`, 0057). The login happened before, in
///   the master, so the channel never asks. Persistence lives in the
///   host's server.
/// - **The foreground probe** (`foregroundProbeArgv`): non-interactive.
///   `BatchMode=yes` + `ConnectTimeout` so a dead host or an auth prompt can
///   never hang it.
///
/// Port, identity, ControlMaster, and IPv6 literals are deliberately not
/// expressible here — point the host field at an `~/.ssh/config` alias for
/// those (the same stance the `path:` grammar took in #137).
enum RemoteSpawn {
    /// Connection timeout for background ops.
    static let opConnectTimeoutSeconds = 5

    /// The ssh destination for a parsed remote: `user@host` or bare `host`.
    static func destination(user: String?, host: String) -> String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    /// How every remote command is delivered: `sh -c '<script>'`.
    ///
    /// NOT `sh -lc`: the login flag is unportable. Debian/Ubuntu `/bin/sh` is
    /// dash, and older dash (e.g. on a real CMU host tested here) rejects `-l`
    /// outright — `sh -lc '…'` then ignores the command and drops to an
    /// interactive shell, silently. `sh -c` runs everywhere. Instead of what
    /// `-l` would have done (source the user's login profiles), `remoteEnvPreamble`
    /// appends a fixed fallback dir list to PATH — profiles are DELIBERATELY
    /// never sourced (see `remoteEnvPreamble` for why every containment attempt
    /// leaked a pane-killer). Naming `sh` explicitly keeps the script POSIX no
    /// matter which login shell sshd hands the outer string to (bash/zsh/fish/nu).
    static let remoteShell = "sh -c"

    /// PATH setup prepended to each script: append the common install dirs.
    /// sshd runs commands non-login/non-interactive with a bare PATH, so a
    /// zmx findable in an interactive session is otherwise invisible over
    /// `ssh host <cmd>`.
    ///
    /// Profiles (`/etc/profile`, `~/.profile`) are DELIBERATELY NOT sourced,
    /// in any form. They are arbitrary code in the pane's critical path, and
    /// every containment attempt leaked a new pane-killing failure mode,
    /// each found on a real or harness host:
    /// - inline + silenced: a `~/.profile` ending in `exec zsh` replaced the
    ///   script wholesale; the exec'd shell inherited stdout→/dev/null
    ///   (prompt visible via ZLE's /dev/tty, keystrokes via kernel pty echo,
    ///   output invisible, zmx never attached);
    /// - subshell harvest: the exec'd shell inherited the pane's tty stdin
    ///   and sat reading keystrokes forever, blocking before attach;
    /// - subshell + stdin</dev/null: a profile exec'ing a login shell that
    ///   re-reads the same profile spins in an exec loop no fd isolation
    ///   can unblock.
    /// The fallback dir list below covers where zmx actually lives in
    /// practice (`~/bin` included), and the project `zmxPath` covers
    /// everything else, deterministically.
    static let remoteEnvPreamble =
        "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; "
            + "export PATH; "

    /// Prepended to the pane script only: settle TERM against the terminfo DB
    /// the remote actually has.
    ///
    /// **A TERM the host can already resolve is never touched** — including a
    /// coarser one the user pinned themselves (`SetEnv TERM=xterm-256color` in
    /// `~/.ssh/config`). Only an unusable arriving TERM is replaced, preferring
    /// `xterm-ghostty` when the host has that entry and falling back to the
    /// universally-known `xterm-256color`, because a TERM with no entry makes
    /// TUIs refuse to start.
    ///
    /// That precedence is load-bearing, and getting it backwards is a regression
    /// that looks like the opposite of one. An earlier revision *preferred*
    /// `xterm-ghostty` whenever the host had it, overriding the pin — and on a
    /// stock Debian host the prompt went monochrome, because the default
    /// `~/.bashrc` gates color on a string match:
    ///
    ///     case "$TERM" in xterm-color|*-256color) color_prompt=yes;; esac
    ///
    /// `xterm-ghostty` matches neither pattern, so a *more* capable terminal
    /// (that entry adds `Tc`; both report 256 colors) rendered a *plainer*
    /// prompt. Capability and dotfile heuristics are different things, and a
    /// pinned TERM is a decision the user already made about both — so we
    /// improve only what was broken anyway. `RemoteTerminfo` still unlocks full
    /// capabilities the honest way: with the entry installed, the TERM ssh
    /// forwards naturally *is* resolvable, so this keeps it instead of
    /// downgrading.
    ///
    /// Decided HOST-side, the deliberate divergence from `ghostty +ssh` — it
    /// forces `-o SetEnv=TERM=xterm-ghostty` from the client because its wrapper
    /// has no remote-side script to work with. Ours does, so it reads the remote
    /// DB directly: no guess about what the host has, no cache to fall out of
    /// sync with reality, and it works where env requests are dropped (see
    /// `remoteColorPreamble` on Tailscale SSH).
    ///
    /// POSIX nested `if`, not `&&`/`||` chaining — the chained form's
    /// left-to-right precedence makes the else-branch bind wrong.
    ///
    /// History, so nobody re-litigates: forcing `xterm-ghostty` was once tried
    /// *unconditionally*, "fixing" panes that rendered a prompt but no output
    /// on a host that has the ghostty terminfo. That experiment was confounded
    /// — the blind arm also sourced a `~/.profile` ending in `exec zsh` (the
    /// actual culprit; see `remoteEnvPreamble`). Retested un-confounded on the
    /// same host: zmx under TERM=xterm-ghostty renders fine. So the value is
    /// safe; what is not safe is imposing it.
    static let remoteTermPreamble =
        "if ! infocmp \"$TERM\" >/dev/null 2>&1; then "
            + "if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty; "
            + "else TERM=xterm-256color; fi; export TERM; fi; "

    /// Prepended to the pane script only: 24-bit color is a property of the
    /// surface, and ours is libghostty — always truecolor — so the remote can
    /// be told unconditionally.
    ///
    /// It has to be asserted host-side because ssh carries only `TERM` by a
    /// channel a server can't refuse: TERM rides the *pty request* (and
    /// OpenSSH ≥8.7 lets `SetEnv` override the value put there), while every
    /// other variable is an `env` channel request the *server* filters. So the
    /// same `SetEnv` flag succeeds or vanishes depending only on which
    /// variable it names — measured against a real host behind Tailscale SSH
    /// (`tailscaled` serves the session, so the host's `AcceptEnv COLORTERM`
    /// is never consulted): `-o SetEnv=TERM=xterm-ghostty` arrived, while
    /// `-o SetEnv=COLORTERM=truecolor`, `-o SendEnv=COLORTERM`, and a control
    /// `-o SetEnv=FOO=bar` all arrived empty. Setting it inside the script
    /// depends on nothing but our own preamble, which is the rule the rest of
    /// this file follows.
    ///
    /// Without it, TUIs that gate 24-bit color on COLORTERM downgrade to 256
    /// colors or refuse outright — helix rejects a truecolor theme with
    /// "Unsupported theme: theme requires true color support". Note the
    /// `remoteTermPreamble` above can't cover this: it only ever *downgrades*
    /// TERM, so a `SetEnv TERM=xterm-256color` in the user's `~/.ssh/config`
    /// (or any host without the ghostty terminfo entry) leaves no truecolor
    /// signal at all. Ghostty.app escapes this by a route we don't have — its
    /// shell-integration `ssh` wrapper hands the connection to `ghostty +ssh`,
    /// which installs the `xterm-ghostty` entry on the host and forces
    /// `-o SetEnv=TERM=xterm-ghostty` (whose terminfo declares `Tc`). A
    /// Macterm pane command IS the surface command, spawned with no shell in
    /// front of it, so no such wrapper can ever run.
    ///
    /// Only sessions created from here on pick it up: `zmx attach` hands its
    /// environment to the shell it CREATES, so a session that predates this
    /// keeps the old one until it is killed.
    static let remoteColorPreamble = "COLORTERM=truecolor; export COLORTERM; "

    /// Prepended to the pane script only, after `remoteColorPreamble` and for
    /// the same reason: `TERM_PROGRAM`/`TERM_PROGRAM_VERSION` describe the
    /// surface, which libghostty sets for a local pane, and an `env` request
    /// carrying them (ghostty's own `ssh-env`, `SSHWrapper`'s `SendEnv`) is
    /// one the server may drop. Programs gate features on them: Claude Code
    /// emits OSC 9;4 progress — the sidebar's busy/done dot for an agent —
    /// only for `TERM_PROGRAM=ghostty` at version 1.2.0 or later, so a remote
    /// agent showed its logo and never its status.
    ///
    /// The version is libghostty's own (`GhosttyApp.version`), exactly what a
    /// local pane sees, and like the rest a process constant. Like COLORTERM,
    /// only sessions created from here on pick it up.
    static let remoteTerminalProgramPreamble = terminalProgramPreamble(version: GhosttyApp.version)

    /// Prepended to the pane script only: asks the host's zmx to push the
    /// session's foreground into the pane's output (`ZmxForegroundEvents`).
    /// The fork's client reads the variable and removes it before the
    /// session starts, so the shell never sees it; an upstream zmx ignores
    /// it, and the pane keeps the probe. Background operations never attach,
    /// so they do not carry it.
    static let remoteForegroundEventsPreamble =
        "\(ZmxForegroundEvents.environmentVariable)=1; export \(ZmxForegroundEvents.environmentVariable); "

    /// Testable core of `remoteTerminalProgramPreamble`. The version is
    /// dropped unless it is all `[A-Za-z0-9.+_-]`, so nothing from it can
    /// reach the shell as syntax; `TERM_PROGRAM` is exported regardless.
    static func terminalProgramPreamble(version: String?) -> String {
        var preamble = "TERM_PROGRAM=ghostty; export TERM_PROGRAM; "
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+_-")
        if let version, !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) {
            preamble += "TERM_PROGRAM_VERSION=\(version); export TERM_PROGRAM_VERSION; "
        }
        return preamble
    }

    /// How the script invokes zmx: a user-supplied absolute path used verbatim
    /// (deterministic — bypasses all PATH resolution), or the bare command
    /// `zmx` resolved through `remoteEnvPreamble`'s PATH setup. `zmxPath` comes
    /// from the project's optional `zmxPath` (New Remote Project sheet / layout
    /// file) — the escape hatch for hosts where PATH resolution can't find it
    /// (network-homed dirs, exotic `/bin/sh`, PATH set only in a non-POSIX
    /// shell config). Double-quoted so a path with spaces survives.
    static func zmxInvocation(zmxPath: String?) -> String {
        guard let zmxPath, !zmxPath.trimmingCharacters(in: .whitespaces).isEmpty else { return "zmx" }
        return posixDoubleQuote(zmxPath.trimmingCharacters(in: .whitespaces))
    }

    /// Where the host's server lives (`server/host/attach.sh`, `d` and `b`).
    static func hostServerBinary(key: String) -> String {
        "$HOME/.local/share/macterm/bin/macterm-\(key)"
    }

    /// What a remote pane runs on the host: the host server's own client of
    /// the session (`macterm-<key> connect <name>`), on the tty of the
    /// pane's ssh channel (0057). `create` adds `--`, so a missing session is
    /// made in `directory` with the user's login shell; without it, a
    /// missing session is an error, never a new shell. Delivered as
    /// `sh -c '<script>'` (see `remoteShell`).
    ///
    /// A binary that is not there (the host lost its files after the check)
    /// exits 255, as a lost link does: the pane then waits, and the next
    /// connect installs again. A folder that is not there prints a line and
    /// starts the session in the home folder, so the shell still persists.
    static func sessionCommand(key: String, sessionName: String, create directory: String?) -> String {
        let binary = posixDoubleQuote(hostServerBinary(key: key)).replacingOccurrences(of: "\\$HOME", with: "$HOME")
        var steps = [
            remoteTermPreamble + remoteColorPreamble + remoteTerminalProgramPreamble + remoteForegroundEventsPreamble
                + "b=\(binary)",
            "[ -x \"$b\" ] || exit 255",
        ]
        var connect = "exec \"$b\" connect \(posixDoubleQuote(sessionName))"
        if let directory {
            let quoted = quoteRemoteDirectory(directory)
            steps.append("cd \(quoted) || { echo \"macterm: cannot cd to \(quoted)\" >&2; cd; }")
            connect += " --"
        }
        steps.append(connect)
        let script = assertSingleQuoteFree(steps.joined(separator: "; "))
        return "\(remoteShell) \(shellQuote(script))"
    }

    /// What a remote pane runs on a host with no server (the user declined
    /// the install, or the host has no build): a plain login shell in
    /// `directory`, as v1 without zmx. It ends with the connection.
    static func plainShellCommand(directory: String) -> String {
        let quoted = quoteRemoteDirectory(directory)
        let script = assertSingleQuoteFree(
            remoteTermPreamble + remoteColorPreamble + remoteTerminalProgramPreamble
                + "cd \(quoted) || echo \"macterm: cannot cd to \(quoted)\" >&2; "
                + "if [ -n \"$SHELL\" ]; then exec \"$SHELL\" -l; else exec /bin/sh; fi"
        )
        return "\(remoteShell) \(shellQuote(script))"
    }

    /// One-round-trip foreground probe for tier-2 remote tab naming and layout
    /// `run:` capture: resolve every `macterm-*` session on the host to its
    /// tty's foreground process — the same session→leader→tpgid→comm pipeline
    /// `ZmxForegroundResolver` runs locally, expressed as portable POSIX sh
    /// (Linux, BSD, macOS remotes). Emits
    /// `session<TAB>comm<TAB>idleflag<TAB>shellflag<TAB>args` lines; parsed by
    /// `RemoteForegroundResolver.parseProbeOutput`. The idle flag is the
    /// HOST's own verdict — `1` when the tty's foreground process group IS
    /// the session leader's (the shell owns its prompt), `0` when some other
    /// group holds it — so busyness never depends on the local Mac's shell
    /// database recognizing a remote-only shell; a failed pgid read emits an
    /// empty flag, which parses as "unknown" and falls back to the local
    /// heuristic rather than inventing a verdict. The shell flag is `1` when
    /// the foreground's name is listed in the HOST's `/etc/shells`, so a
    /// shell the Mac has never seen (`elvish`, `xonsh`) still counts as a
    /// shell when it is nested inside the session's own; `0` otherwise, and
    /// empty when the host has no `/etc/shells` to ask. Terminal multiplexers
    /// are always `0`: Debian's tmux and screen packages add themselves to
    /// `/etc/shells`, but `tmux attach` is a program to record and title. `args` is the foreground's
    /// full command line (the remote analogue of the local KERN_PROCARGS2
    /// argv that Save Layout records as `run:`) — it may contain tabs, so it
    /// is the LAST field, consumed as the unsplit remainder.
    ///
    /// Deliberately contains NO single quotes: it ships to the host wrapped
    /// as `sh -c '<script>'`, and the outer quoting must survive any login
    /// shell (see `remoteShell`).
    /// `<ZMX>` is substituted with the resolved zmx invocation (bare `zmx` or
    /// the explicit quoted path) before shipping.
    static let foregroundProbeScript = """
    <ZMX> ls 2>/dev/null | while read -r line; do
      n=; p=
      for f in $line; do
        case "$f" in
          name=*) n=${f#name=} ;;
          pid=*) p=${f#pid=} ;;
        esac
      done
      case "$n" in macterm-*) ;; *) continue ;; esac
      case "$p" in ""|*[!0-9]*) continue ;; esac
      t=$(ps -o tpgid= -p "$p" 2>/dev/null | tr -d " ")
      [ -n "$t" ] || continue
      c=$(ps -o comm= -p "$t" 2>/dev/null)
      [ -n "$c" ] || continue
      g=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d " ")
      i=
      if [ -n "$g" ]; then
        if [ "$t" = "$g" ]; then i=1; else i=0; fi
      fi
      s=
      if [ -r /etc/shells ]; then
        s=0; b=${c##*/}; b=${b#-}
        case "$b" in
          tmux|screen|zellij) ;;
          *) while read -r l; do
               case "$l" in */"$b") s=1; break ;; esac
             done < /etc/shells ;;
        esac
      fi
      a=$(ps -o args= -p "$t" 2>/dev/null)
      printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$n" "$c" "$i" "$s" "$a"
    done
    """

    /// argv (for `/usr/bin/ssh`) running the foreground probe on the remote
    /// host — non-interactive (`BatchMode`), `sh -c`-wrapped so
    /// any login shell delivers it intact. `zmxPath` (optional) is used
    /// verbatim. nil for a local path.
    static func foregroundProbeArgv(remote: ProjectPath, zmxPath: String? = nil) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let script = assertSingleQuoteFree(
            remoteEnvPreamble
                + foregroundProbeScript.replacingOccurrences(of: "<ZMX>", with: zmxInvocation(zmxPath: zmxPath)),
            onViolation: .failNonZero
        )
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "\(remoteShell) \(shellQuote(script))",
        ]
    }

    /// The git reads of the memory panel for a remote project, in one
    /// connection (`ProjectGit.remoteStatus`): the same five reads that
    /// `ProjectGit.status` runs locally, with their outputs separated by
    /// `ProjectGit.recordSeparator`. The script exits 2 when the directory
    /// is not there, 3 when the host has no git, 4 when the directory is not
    /// in a repository, and 0 in all other cases (`ProjectGit.branchLogScript`
    /// fails on a detached HEAD, which is not a failure of the read); ssh
    /// itself exits 255. `GIT_OPTIONAL_LOCKS=0` and
    /// `core.fsmonitor=false` for the same reasons as locally. Never sources
    /// a profile (see `remoteEnvPreamble`). nil for a local path.
    static func gitProbeArgv(remote: ProjectPath) -> [String]? {
        guard case let .remote(user, host, directory) = remote else { return nil }
        let git = (["git"] + ProjectGit.gitOptions).joined(separator: " ")
        let separator = "printf \"\\036\""
        let branchFormat = "%(refname:short)%1f%(objectname:short)%1f%(committerdate:unix)%1f%(subject)"
        let script = assertSingleQuoteFree(
            remoteEnvPreamble
                + "GIT_OPTIONAL_LOCKS=0; GIT_TERMINAL_PROMPT=0; export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT; "
                + "cd \(quoteRemoteDirectory(directory)) 2>/dev/null || exit 2; "
                + "command -v git >/dev/null 2>&1 || exit 3; "
                + "\(git) status --porcelain=v2 --branch --show-stash 2>/dev/null || exit 4; \(separator); "
                + "\(git) log -\(ProjectGit.recentCommitCount) --format=%h%x1f%s%x1f%ct 2>/dev/null; \(separator); "
                + "\(git) for-each-ref refs/heads --sort=-committerdate --count=\(ProjectGit.recentBranchCount) "
                + "--format=\"\(branchFormat)\" 2>/dev/null; \(separator); "
                + "\(git) worktree list --porcelain 2>/dev/null; \(separator); "
                + "{ \(ProjectGit.branchLogScript(git: git)); } 2>/dev/null; exit 0",
            onViolation: .failNonZero
        )
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "\(remoteShell) \(shellQuote(script))",
        ]
    }

    /// POSIX single-quote escaping: safe against spaces, globs, `$`, and
    /// embedded quotes (`'` → `'\''`). For strings parsed by a shell that is
    /// KNOWN to be POSIX — the local bash ghostty spawns through, or the
    /// inside of an `sh -c` script. Never for text a remote login shell
    /// tokenizes with embedded quotes present (see `remoteShell`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// POSIX double-quote escaping (`\`, `"`, `$`, backtick), used INSIDE the
    /// `sh -c` scripts so the script itself stays free of single quotes.
    ///
    /// A single quote in `value` is passed through literally (double quotes
    /// don't escape `'`), which would violate the single-quote-free wire-format
    /// invariant: `shellQuote` would then emit `'\''`, and fish/nu tokenize that
    /// differently than POSIX sh. Callers that feed user-controlled fields
    /// (project directory, `zmxPath`) must reject `'` upstream — see
    /// `assertSingleQuoteFree` — so this can never receive one in practice.
    static func posixDoubleQuote(_ value: String) -> String {
        var escaped = ""
        for ch in value {
            if ch == "\\" || ch == "\"" || ch == "$" || ch == "`" {
                escaped.append("\\")
            }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// What a script does when the single-quote-free invariant is violated.
    enum QuoteViolationFallback {
        /// Interactive pane: drop into a shell so the pane stays usable and the
        /// user sees the diagnostic (a bare exit would vanish the pane).
        case dropToShell
        /// Background op (kill / probe): exit NON-zero so the caller sees an
        /// honest failure instead of a silent no-op that reports success.
        case failNonZero
    }

    /// The wire-format invariant: an assembled remote script must contain NO
    /// single quotes, so `sh -c '<script>'` tokenizes identically under every
    /// login shell (bash/zsh/fish/nu). Returns the script unchanged when it
    /// holds, or a safe diagnostic script (never nil, never a `'`) when a
    /// user-supplied field smuggled one in — so the caller surfaces the problem
    /// instead of mistokenizing on a non-POSIX login shell.
    static func assertSingleQuoteFree(
        _ script: String,
        onViolation fallback: QuoteViolationFallback = .dropToShell
    ) -> String {
        guard script.contains("'") else { return script }
        // Keep the replacement itself single-quote-free.
        let diagnostic = "echo \"macterm: remote path contains an unsupported single quote\" >&2; "
        switch fallback {
        case .dropToShell:
            return remoteEnvPreamble + diagnostic + "exec ${SHELL:-/bin/sh}"
        case .failNonZero:
            // No shell exec — a kill/probe with a bad path should FAIL, not
            // land in an interactive shell that exits 0.
            return diagnostic + "exit 1"
        }
    }

    /// Quote a remote directory for the `cd` inside the `sh -c` script,
    /// keeping ONLY a leading `~` or `~username` *unquoted* so sh still expands
    /// it (`~`, `~/dev with spaces`, `~deploy/app`). A quoted tilde is a literal
    /// directory named `~`, so the tilde itself can't be quoted — but anything
    /// past it (and any `~username` segment) is either double-quoted or, if it
    /// isn't a valid bare-safe username, the whole string falls back to full
    /// double-quoting. This closes the hole where `~$(cmd)/sub` (or a slashless
    /// `~$(cmd)`) shipped a command substitution unquoted into the `cd` line.
    static func quoteRemoteDirectory(_ directory: String) -> String {
        guard directory.hasPrefix("~") else { return posixDoubleQuote(directory) }
        // Split into the tilde segment (`~` or `~name`) and the remainder.
        let afterTilde = directory.index(after: directory.startIndex)
        let slashIndex = directory[afterTilde...].firstIndex(of: "/")
        let tildeSegment = String(directory[..<(slashIndex ?? directory.endIndex)])
        // The username part between `~` and the first `/` (empty for a bare `~`).
        let username = String(tildeSegment.dropFirst())
        // A bare-safe username is a strict allowlist; anything else (spaces,
        // `$`, backticks, command substitution) must NOT ship unquoted.
        let usernameIsSafe = username.isEmpty
            || username.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        guard usernameIsSafe else { return posixDoubleQuote(directory) }
        guard let slashIndex else {
            // No slash: the whole string is just `~` or `~name` — emit the
            // validated tilde segment bare (nothing else to quote).
            return tildeSegment
        }
        let rest = String(directory[directory.index(after: slashIndex)...])
        return rest.isEmpty ? "\(tildeSegment)/" : "\(tildeSegment)/\(posixDoubleQuote(rest))"
    }
}
