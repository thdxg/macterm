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
    /// interactive shell, silently. `sh -c` runs everywhere. We reproduce
    /// what `-l` was for (loading the user's PATH) by sourcing the profiles
    /// ourselves in `remoteEnvPreamble`. Naming `sh` explicitly keeps the
    /// script POSIX no matter which login shell sshd hands the outer string to
    /// (bash/zsh/fish/nu).
    static let remoteShell = "sh -c"

    /// PATH setup prepended to each script. sshd runs commands
    /// non-login/non-interactive with a bare PATH, so a zmx findable in an
    /// interactive session is otherwise invisible over `ssh host <cmd>`. Two
    /// best-effort steps, in order:
    ///
    /// 1. Harvest PATH from `/etc/profile` + `~/.profile` sourced inside a
    ///    COMMAND-SUBSTITUTION SUBSHELL — never in our own shell. Profiles
    ///    are arbitrary code: a real host's `~/.profile` ended in `exec zsh`,
    ///    which (sourced inline under our `>/dev/null` silencing) replaced
    ///    the script wholesale — the exec'd shell inherited stdout→/dev/null,
    ///    producing a pane with a visible prompt (ZLE writes to /dev/tty),
    ///    visible keystrokes (kernel pty echo), and invisible command output,
    ///    with zmx never attached. In a subshell, an `exec`/`exit`/abort can
    ///    only kill the subshell: the substitution comes back empty and we
    ///    fall through. The harvested PATH is adopted only when non-empty.
    /// 2. Append the common install dirs as a last resort — `~/bin` first,
    ///    preserving `$PATH` so anything the profiles set keeps precedence.
    ///    Covers hosts whose PATH lives only in a non-POSIX shell's config
    ///    (fish/nu), which `sh` never reads.
    ///
    /// A user-supplied absolute zmx path (project `zmxPath`) bypasses all of
    /// this — see `paneCommand`.
    static let remoteEnvPreamble =
        "mt_path=$( { . /etc/profile; . \"$HOME/.profile\"; } >/dev/null 2>&1; printf %s \"$PATH\" ) || true; "
            + "[ -n \"$mt_path\" ] && PATH=\"$mt_path\"; unset mt_path; "
            + "PATH=\"$PATH:$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin\"; "
            + "export PATH; "

    /// Prepended to the pane script only: ssh forwards the local
    /// TERM=xterm-ghostty, which most remotes have no terminfo entry for —
    /// TUIs would refuse to start. Fall back to the universally-known
    /// xterm-256color unless the remote actually knows the current TERM;
    /// hosts whose ncurses ships the ghostty entry keep full capabilities
    /// (truecolor, styled underlines).
    ///
    /// History, so nobody re-litigates: this was briefly unconditional,
    /// "fixing" panes that rendered a prompt but no output on a host that
    /// has the ghostty terminfo. That experiment was confounded — the blind
    /// arm also sourced a `~/.profile` ending in `exec zsh` (the actual
    /// culprit; see `remoteEnvPreamble`). Retested un-confounded on the same
    /// host: zmx under TERM=xterm-ghostty renders fine.
    static let remoteTermPreamble =
        "infocmp \"$TERM\" >/dev/null 2>&1 || { TERM=xterm-256color; export TERM; }; "

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
        let script = remoteEnvPreamble + remoteTermPreamble + [
            zmxPresenceGuard(zmx: zmx, fallbackShell: fallbackShell),
            "cd \(quotedDir) || "
                + "{ echo \"macterm: cannot cd to \(quotedDir)\" >&2; \(fallbackShell); }",
            "exec \(zmx) attach \(quotedSession)",
        ].compactMap(\.self).joined(separator: "; ")
        let remoteCommand = "\(remoteShell) \(shellQuote(script))"
        return "ssh -t \(shellQuote(destination(user: user, host: host))) \(shellQuote(remoteCommand))"
    }

    /// argv (for `/usr/bin/ssh`) running a background `zmx` operation on the
    /// remote host, `sh -c`-wrapped like every remote command. `zmxPath`
    /// (optional) is used verbatim. nil for a local path.
    static func opArgv(remote: ProjectPath, zmxArguments: [String], zmxPath: String? = nil) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let op = remoteEnvPreamble + "exec \(zmxInvocation(zmxPath: zmxPath)) "
            + zmxArguments.map(posixDoubleQuote).joined(separator: " ")
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "\(remoteShell) \(shellQuote(op))",
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
      printf "%s\\t%s\\n" "$n" "$c"
    done
    """

    /// argv (for `/usr/bin/ssh`) running the foreground probe on the remote
    /// host — the same non-interactive profile as `opArgv`, `sh -c`-wrapped so
    /// any login shell delivers it intact. `zmxPath` (optional) is used
    /// verbatim. nil for a local path.
    static func foregroundProbeArgv(remote: ProjectPath, zmxPath: String? = nil) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let script = remoteEnvPreamble
            + foregroundProbeScript.replacingOccurrences(of: "<ZMX>", with: zmxInvocation(zmxPath: zmxPath))
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
