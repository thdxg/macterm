import Foundation

/// Builds the commands behind remote projects (#104). Pure string assembly:
/// every command line is unit-testable without a host.
///
/// - **A pane's command** (`sessionCommand`, `plainShellCommand`): it runs
///   on the tty of an ssh channel over the host's one connection
///   (`SSHConnections.ttyArguments`, 0057). The login happened before, in
///   the master, so the channel never asks. Persistence lives in the
///   host's server.
/// - **A background read** (`gitProbeScript`): the host's server runs it
///   (`RemoteHosts.run`, 0058). It opens no connection of its own.
///
/// Port, identity, ControlMaster, and IPv6 literals are deliberately not
/// expressible here — point the host field at an `~/.ssh/config` alias for
/// those (the same stance the `path:` grammar took in #137).
enum RemoteSpawn {
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

    /// Where the host's server lives (`server/host/attach.sh`, `d` and `b`).
    static func hostServerBinary(key: String) -> String {
        "$HOME/.local/share/macterm/bin/macterm-\(key)"
    }

    /// What a new remote session needs from the host, in one command that the
    /// host's server runs (`command.run`): the first line says if the folder
    /// is there (`ok`) or the pane falls back to the home folder (`home`),
    /// the second is the folder's physical path, and the rest is the
    /// environment after the same settling of `TERM`, `COLORTERM` and
    /// `TERM_PROGRAM` that a pane's script did. Never sources a profile.
    /// `session.create` has no shell to expand a `~`, so the host resolves it.
    static func createProbeScript(directory: String) -> String {
        // No ssh pty gave the server a TERM. A shell may set a `dumb` one that
        // it does not export: replace it, and export the result.
        "case \"$TERM\" in \"\"|dumb) TERM=xterm-256color; infocmp xterm-ghostty >/dev/null 2>&1 && TERM=xterm-ghostty;; esac; "
            + "export TERM; "
            + remoteTermPreamble + remoteColorPreamble + remoteTerminalProgramPreamble
            + "if cd \(quoteRemoteDirectory(directory)) 2>/dev/null; then echo ok; else echo home; cd; fi; pwd -P; env"
    }

    /// True for a folder that may go into a host command: a path (absolute,
    /// or from `~`) with no control character, no backslash and no single
    /// quote. A folder that the host reported (OSC 7) is the host's text: a
    /// backslash leaves `"…"` under fish, and a control character is never a
    /// folder the user typed.
    static func isSafeHostFolder(_ folder: String) -> Bool {
        guard folder.hasPrefix("/") || folder.hasPrefix("~") else { return false }
        return !folder.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0 == "\\" || $0 == "'"
        }
    }

    /// What a remote pane runs on a host with no server (the user declined
    /// the install, or the host has no build): a plain login shell in
    /// `directory`, as v1 without zmx. It ends with the connection.
    static func plainShellCommand(directory: String) -> String {
        let quoted = quoteRemoteDirectory(directory)
        let script = assertSingleQuoteFree(
            remoteTermPreamble + remoteColorPreamble + remoteTerminalProgramPreamble
                + "cd \(quoted) || echo \"macterm: cannot cd to\" \(quoted) >&2; "
                + "if [ -n \"$SHELL\" ]; then exec \"$SHELL\" -l; else exec /bin/sh; fi"
        )
        return "\(remoteShell) \(shellQuote(script))"
    }

    /// The git reads of the memory panel for a remote project, in one
    /// command that the host's server runs (`ProjectGit.remoteStatus`): the
    /// same six reads that `ProjectGit.status` runs locally, with their
    /// outputs separated by `ProjectGit.recordSeparator`. The diff runs only
    /// when the status has a changed tracked file (a line that starts with
    /// `1`, `2` or `u`), as locally. The script exits 2 when the directory
    /// is not there, 3 when the host has no git, 4 when the directory is not
    /// in a repository, and 0 in all other cases (`ProjectGit.branchLogScript`
    /// fails on a detached HEAD, which is not a failure of the read).
    /// `GIT_OPTIONAL_LOCKS=0` and `core.fsmonitor=false` for the same reasons
    /// as locally. Never sources a profile (see `remoteEnvPreamble`).
    static func gitProbeScript(directory: String) -> String {
        let git = (["git"] + ProjectGit.gitOptions).joined(separator: " ")
        let separator = "printf \"\\036\""
        let branchFormat = "%(refname:short)%1f%(objectname:short)%1f%(committerdate:unix)%1f%(subject)"
        return remoteEnvPreamble
            + "GIT_OPTIONAL_LOCKS=0; GIT_TERMINAL_PROMPT=0; export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT; "
            + "cd \(quoteRemoteDirectory(directory)) 2>/dev/null || exit 2; "
            + "command -v git >/dev/null 2>&1 || exit 3; "
            + "s=$(\(git) status --porcelain=v2 --branch --show-stash 2>/dev/null) || exit 4; "
            + "printf \"%s\\n\" \"$s\"; \(separator); "
            + "\(git) log -\(ProjectGit.recentCommitCount) --format=%h%x1f%s%x1f%ct 2>/dev/null; \(separator); "
            + "\(git) for-each-ref refs/heads --sort=-committerdate --count=\(ProjectGit.recentBranchCount) "
            + "--format=\"\(branchFormat)\" 2>/dev/null; \(separator); "
            + "\(git) worktree list --porcelain 2>/dev/null; \(separator); "
            + "{ \(ProjectGit.branchLogScript(git: git)); } 2>/dev/null; \(separator); "
            + "if printf \"%s\\n\" \"$s\" | grep -q \"^[12u] \"; then "
            + "\(ProjectGit.diffCommand(git: git)); fi; exit 0"
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

    /// The wire-format invariant: an assembled remote script must contain NO
    /// single quotes, so `sh -c '<script>'` tokenizes identically under every
    /// login shell (bash/zsh/fish/nu). Returns the script unchanged when it
    /// holds, or a safe diagnostic script (never a `'`) when a user-supplied
    /// field smuggled one in: the pane shows the diagnostic and drops into a
    /// shell, so it stays usable (a bare exit would vanish the pane).
    static func assertSingleQuoteFree(_ script: String) -> String {
        guard script.contains("'") else { return script }
        // Keep the replacement itself single-quote-free.
        return remoteEnvPreamble
            + "echo \"macterm: remote path contains an unsupported single quote\" >&2; "
            + "exec ${SHELL:-/bin/sh}"
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
