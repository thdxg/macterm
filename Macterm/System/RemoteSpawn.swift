import Foundation

/// Builds the ssh invocations behind remote projects (#104). Pure string
/// assembly — every command line is unit-testable without a host.
///
/// Two deliberately different ssh profiles:
/// - **The pane command** (`paneCommand`): interactive. `-t` forces a tty and
///   there is NO BatchMode, so password/2FA prompts render inside the pane
///   and interactive auth just works. It cd's into the project directory and
///   exec's `zmx attach <session>` — persistence lives entirely in the
///   *remote* daemon. A local zmx wrapper must never be layered on top:
///   nested zmx (a local session wrapping an ssh'd remote attach) is broken
///   upstream.
/// - **Background ops** (`opArgv`): non-interactive `zmx <args>` (kill/ls).
///   `BatchMode=yes` + `ConnectTimeout` so a dead host or an auth prompt can
///   never hang a close/quit path.
///
/// Port, identity, ControlMaster, and IPv6 literals are deliberately not
/// expressible here — point the host field at an `~/.ssh/config` alias for
/// those (the same stance the `path:` grammar took in #137).
enum RemoteSpawn {
    /// Connection timeout for background ops. The pane command gets none —
    /// a human is watching it and may be typing a passphrase.
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
    /// everything else, deterministically — see `paneCommand`.
    static let remoteEnvPreamble =
        "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; "
            + "export PATH; "

    /// Prepended to the pane script only: settle TERM against the terminfo DB
    /// the remote actually has.
    ///
    /// `xterm-ghostty` when the host knows it — full capabilities (truecolor,
    /// styled underlines) — else whatever ssh forwarded if the host knows
    /// *that*, else the universally-known `xterm-256color`, because a TERM with
    /// no entry makes TUIs refuse to start. Both branches matter: ssh forwards
    /// the local `xterm-ghostty` which most hosts can't resolve, and a user's
    /// `~/.ssh/config` may pin something coarser (`SetEnv TERM=xterm-256color`)
    /// which we should improve on when the host can do better.
    ///
    /// The upgrade is decided HOST-side, which is the deliberate divergence
    /// from `ghostty +ssh` — it forces `-o SetEnv=TERM=xterm-ghostty` from the
    /// client because its wrapper has no remote-side script to work with. Ours
    /// does, so it reads the remote DB directly: no guess about what the host
    /// has, no cache to fall out of sync with reality, and it works where env
    /// requests are dropped (see `remoteColorPreamble` on Tailscale SSH).
    /// `RemoteTerminfo` is what makes a host that lacks the entry acquire it,
    /// so a later session takes the first branch.
    ///
    /// POSIX `if`/`elif`, not `&&`/`||` chaining — the chained form's
    /// left-to-right precedence makes the else-branch bind wrong.
    ///
    /// History, so nobody re-litigates: forcing `xterm-ghostty` was once tried
    /// *unconditionally*, "fixing" panes that rendered a prompt but no output
    /// on a host that has the ghostty terminfo. That experiment was confounded
    /// — the blind arm also sourced a `~/.profile` ending in `exec zsh` (the
    /// actual culprit; see `remoteEnvPreamble`). Retested un-confounded on the
    /// same host: zmx under TERM=xterm-ghostty renders fine. What was wrong
    /// with it was being unconditional, not the value.
    static let remoteTermPreamble =
        "if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty; export TERM; "
            + "elif ! infocmp \"$TERM\" >/dev/null 2>&1; then TERM=xterm-256color; export TERM; fi; "

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

    /// Whether the zmx-presence guard is needed: only when relying on PATH
    /// resolution. An explicit path is used directly (its failure surfaces as
    /// zmx's own error, still visible in the pane).
    private static func zmxPresenceGuard(zmx: String, fallbackShell: String) -> String? {
        zmx == "zmx"
            ? "command -v zmx >/dev/null 2>&1 || "
            + "{ echo \"macterm: zmx not found in PATH on this host ($PATH)\" >&2; \(fallbackShell); }"
            : nil
    }

    /// The surface command for a remote pane, as the single string handed to
    /// ghostty's `command`: `ssh -t <dest> 'sh -c <script>'`. nil for a local
    /// path. `zmxPath` (optional) is an absolute remote zmx path used verbatim.
    ///
    /// Delivered as `sh -c '<single-quote-free script>'` (see `remoteShell`):
    /// portable across every `/bin/sh`, and the single-quoted argument
    /// tokenizes identically whether sshd hands the outer string to bash, zsh,
    /// fish, or nu.
    static func paneCommand(remote: ProjectPath, sessionName: String, zmxPath: String? = nil) -> String? {
        guard case let .remote(user, host, directory) = remote else { return nil }
        // On failure DON'T let the script exit — that closes the pane with no
        // explanation (the surface's command exiting fires closeSurface).
        // Instead print a diagnostic and drop into a shell so the failure is
        // visible and the pane is still usable. Only the happy path `exec`s
        // zmx (replacing the shell, so its exit is the session detaching).
        let quotedDir = quoteRemoteDirectory(directory)
        let quotedSession = posixDoubleQuote(sessionName)
        let zmx = zmxInvocation(zmxPath: zmxPath)
        // `${SHELL:-/bin/sh}`: fall back to /bin/sh when the remote leaves
        // $SHELL unset, so the diagnostic shell can never itself exit-and-close
        // the pane. No `-l` (unportable — see remoteShell).
        let fallbackShell = "exec ${SHELL:-/bin/sh}"
        let script = assertSingleQuoteFree(remoteEnvPreamble + remoteTermPreamble + remoteColorPreamble + [
            zmxPresenceGuard(zmx: zmx, fallbackShell: fallbackShell),
            "cd \(quotedDir) || "
                + "{ echo \"macterm: cannot cd to \(quotedDir)\" >&2; \(fallbackShell); }",
            "exec \(zmx) attach \(quotedSession)",
        ].compactMap(\.self).joined(separator: "; "))
        let remoteCommand = "\(remoteShell) \(shellQuote(script))"
        return "ssh -t \(shellQuote(destination(user: user, host: host))) \(shellQuote(remoteCommand))"
    }

    /// argv (for `/usr/bin/ssh`) running a background `zmx` operation on the
    /// remote host, `sh -c`-wrapped like every remote command. `zmxPath`
    /// (optional) is used verbatim. nil for a local path.
    static func opArgv(remote: ProjectPath, zmxArguments: [String], zmxPath: String? = nil) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let op = assertSingleQuoteFree(
            remoteEnvPreamble + "exec \(zmxInvocation(zmxPath: zmxPath)) "
                + zmxArguments.map(posixDoubleQuote).joined(separator: " "),
            onViolation: .failNonZero
        )
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "\(remoteShell) \(shellQuote(op))",
        ]
    }

    /// One-round-trip foreground probe for tier-2 remote tab naming and layout
    /// `run:` capture: resolve every `macterm-*` session on the host to its
    /// tty's foreground process — the same session→leader→tpgid→comm pipeline
    /// `ZmxForegroundResolver` runs locally, expressed as portable POSIX sh
    /// (Linux, BSD, macOS remotes). Emits
    /// `session<TAB>comm<TAB>idleflag<TAB>args` lines; parsed by
    /// `RemoteForegroundResolver.parseProbeOutput`. The idle flag is the
    /// HOST's own verdict — `1` when the tty's foreground process group IS
    /// the session leader's (the shell owns its prompt), `0` when some other
    /// group holds it — so busyness never depends on the local Mac's shell
    /// database recognizing a remote-only shell; a failed pgid read emits an
    /// empty flag, which parses as "unknown" and falls back to the local
    /// heuristic rather than inventing a verdict. `args` is the foreground's
    /// full command line (the remote analogue of the local KERN_PROCARGS2
    /// argv that Save Layout records as `run:`) — it may contain tabs, so it
    /// is the LAST field, consumed as the unsplit remainder.
    ///
    /// Deliberately contains NO single quotes: it ships to the host wrapped
    /// as `sh -c '<script>'`, and the outer quoting must survive any login
    /// shell (see `paneCommand`).
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
      a=$(ps -o args= -p "$t" 2>/dev/null)
      printf "%s\\t%s\\t%s\\t%s\\n" "$n" "$c" "$i" "$a"
    done
    """

    /// argv (for `/usr/bin/ssh`) running the foreground probe on the remote
    /// host — the same non-interactive profile as `opArgv`, `sh -c`-wrapped so
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

    /// POSIX single-quote escaping: safe against spaces, globs, `$`, and
    /// embedded quotes (`'` → `'\''`). For strings parsed by a shell that is
    /// KNOWN to be POSIX — the local bash ghostty spawns through, or the
    /// inside of an `sh -c` script. Never for text a remote login shell
    /// tokenizes with embedded quotes present (see `paneCommand`).
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
