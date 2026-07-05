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

    /// Prepended to every remote `sh -c` script: extend PATH with the places
    /// zmx commonly lives. sshd's default PATH is bare and non-POSIX login
    /// shells (fish, nushell) don't source the profiles that would add user
    /// dirs — a zmx findable in an interactive session can be invisible to
    /// `ssh host <cmd>`. Extended, never replaced: an existing PATH wins.
    ///
    /// Covers the usual user-bin dirs (`~/bin`, `~/.local/bin`) and the
    /// common system prefixes (`/usr/local/bin` Linux/Intel-mac, `~/.cargo/bin`
    /// for a cargo-installed zmx, `/opt/homebrew/bin` Apple-silicon mac).
    static let remotePathPreamble =
        "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; "
            + "export PATH; "

    /// Prepended to the pane script only: ssh forwards the local
    /// TERM=xterm-ghostty, which most remotes have no terminfo entry for
    /// (ghostty's own ssh-terminfo integration only helps the external CLI's
    /// wrapper, not our direct spawn) — TUIs would refuse to start. Fall back
    /// to the universally-known xterm-256color unless the remote actually
    /// knows the current TERM.
    static let remoteTermPreamble =
        "infocmp \"$TERM\" >/dev/null 2>&1 || { TERM=xterm-256color; export TERM; }; "

    /// The surface command for a remote pane, as the single string handed to
    /// ghostty's `command`: `ssh -t <dest> 'sh -c <script>'`. nil for a local
    /// path.
    ///
    /// The remote side is wrapped in `sh -c` because sshd executes the
    /// command string through the user's LOGIN shell — and `&&`, tilde-plus-
    /// quote splicing, or `'\''` escapes are POSIX-isms a fish/nushell login
    /// shell won't parse. `sh -c '<script>'` with a single-quote-free script
    /// tokenizes identically in bash, zsh, fish, and nu (all treat a
    /// single-quoted word as one literal argument), and the script itself
    /// then runs under POSIX sh regardless of the login shell.
    static func paneCommand(remote: ProjectPath, sessionName: String) -> String? {
        guard case let .remote(user, host, directory) = remote else { return nil }
        // If zmx isn't on the (non-interactive) PATH, DON'T let the script
        // exit — that closes the pane with no explanation (the surface's
        // command exiting fires closeSurface). Instead print a diagnostic and
        // drop into a plain login shell so the failure is visible and the pane
        // is still usable. Same for a `cd` into a missing directory. Only the
        // happy path `exec`s zmx (replacing the shell, so its exit is the
        // session detaching, not an error).
        let quotedDir = quoteRemoteDirectory(directory)
        let quotedSession = posixDoubleQuote(sessionName)
        // `${SHELL:-/bin/sh} -l`: a login shell, falling back to /bin/sh when
        // the remote leaves $SHELL unset — so the diagnostic fallback can
        // never itself exit-and-close the pane.
        let fallbackShell = "exec ${SHELL:-/bin/sh} -l"
        let script = remotePathPreamble + remoteTermPreamble + [
            "command -v zmx >/dev/null 2>&1 || "
                + "{ echo \"macterm: zmx not found in PATH on this host ($PATH)\" >&2; \(fallbackShell); }",
            "cd \(quotedDir) || "
                + "{ echo \"macterm: cannot cd to \(quotedDir)\" >&2; \(fallbackShell); }",
            "exec zmx attach \(quotedSession)",
        ].joined(separator: "; ")
        let remoteCommand = "sh -c \(shellQuote(script))"
        return "ssh -t \(shellQuote(destination(user: user, host: host))) \(shellQuote(remoteCommand))"
    }

    /// argv (for `/usr/bin/ssh`) running a background `zmx` operation on the
    /// remote host, `sh -c`-wrapped like every remote command (login-shell
    /// portability + the PATH preamble). nil for a local path.
    static func opArgv(remote: ProjectPath, zmxArguments: [String]) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let op = remotePathPreamble + "exec zmx "
            + zmxArguments.map(posixDoubleQuote).joined(separator: " ")
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "sh -c \(shellQuote(op))",
        ]
    }

    /// One-round-trip foreground probe for tier-2 remote tab naming: resolve
    /// every `macterm-*` session on the host to its tty's foreground process
    /// name — the same session→leader→tpgid→comm pipeline
    /// `ZmxForegroundResolver` runs locally, expressed as portable POSIX sh
    /// (Linux, BSD, macOS remotes). Emits `session<TAB>comm` lines; parsed by
    /// `RemoteForegroundResolver.parseProbeOutput`.
    ///
    /// Deliberately contains NO single quotes: it ships to the host wrapped
    /// as `sh -c '<script>'`, and the outer quoting must survive any login
    /// shell (see `paneCommand`).
    static let foregroundProbeScript = """
    zmx ls 2>/dev/null | while read -r line; do
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
      printf "%s\\t%s\\n" "$n" "$c"
    done
    """

    /// argv (for `/usr/bin/ssh`) running the foreground probe on the remote
    /// host — the same non-interactive profile as `opArgv`, with the script
    /// wrapped in `sh -c` so any login shell delivers it intact. nil for a
    /// local path.
    static func foregroundProbeArgv(remote: ProjectPath) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "sh -c \(shellQuote(remotePathPreamble + foregroundProbeScript))",
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

    /// Quote a remote directory for the `cd` inside the `sh -c` script,
    /// keeping a leading tilde segment *unquoted* so sh still expands it
    /// (`~`, `~/dev with spaces`, `~deploy/app`). A quoted tilde is a literal
    /// directory named `~`. Everything after the tilde segment is
    /// double-quoted; plain paths (absolute or home-relative) are quoted
    /// whole.
    static func quoteRemoteDirectory(_ directory: String) -> String {
        guard directory.hasPrefix("~") else { return posixDoubleQuote(directory) }
        guard let slash = directory.firstIndex(of: "/") else { return directory }
        let tilde = String(directory[..<slash])
        let rest = String(directory[directory.index(after: slash)...])
        return rest.isEmpty ? directory : "\(tilde)/\(posixDoubleQuote(rest))"
    }
}
