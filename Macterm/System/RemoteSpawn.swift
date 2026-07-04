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

    /// The surface command for a remote pane, as the single string handed to
    /// ghostty's `command`: `ssh -t <dest> '<cd … && exec zmx attach …>'`.
    /// nil for a local path.
    static func paneCommand(remote: ProjectPath, sessionName: String) -> String? {
        guard case let .remote(user, host, directory) = remote else { return nil }
        let attach = "cd \(quoteRemoteDirectory(directory)) && exec zmx attach \(shellQuote(sessionName))"
        return "ssh -t \(shellQuote(destination(user: user, host: host))) \(shellQuote(attach))"
    }

    /// argv (for `/usr/bin/ssh`) running a background `zmx` operation on the
    /// remote host. nil for a local path.
    static func opArgv(remote: ProjectPath, zmxArguments: [String]) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            "zmx",
        ] + zmxArguments.map(shellQuote)
    }

    /// One-round-trip foreground probe for tier-2 remote tab naming: resolve
    /// every `macterm-*` session on the host to its tty's foreground process
    /// name — the same session→leader→tpgid→comm pipeline
    /// `ZmxForegroundResolver` runs locally, expressed as portable POSIX sh
    /// (Linux, BSD, macOS remotes). Emits `session<TAB>comm` lines; parsed by
    /// `RemoteForegroundResolver.parseProbeOutput`.
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
      case "$p" in ''|*[!0-9]*) continue ;; esac
      t=$(ps -o tpgid= -p "$p" 2>/dev/null | tr -d ' ')
      [ -n "$t" ] || continue
      c=$(ps -o comm= -p "$t" 2>/dev/null)
      [ -n "$c" ] || continue
      printf '%s\\t%s\\n' "$n" "$c"
    done
    """

    /// argv (for `/usr/bin/ssh`) running the foreground probe on the remote
    /// host — the same non-interactive profile as `opArgv`. nil for a local
    /// path.
    static func foregroundProbeArgv(remote: ProjectPath) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(opConnectTimeoutSeconds)",
            destination(user: user, host: host),
            foregroundProbeScript,
        ]
    }

    /// POSIX single-quote escaping: safe against spaces, globs, `$`, and
    /// embedded quotes (`'` → `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote a remote directory for `cd`, keeping a leading tilde segment
    /// *unquoted* so the remote shell still expands it (`~`, `~/dev with
    /// spaces`, `~deploy/app`). A quoted tilde is a literal directory named
    /// `~`. Everything after the tilde segment is quoted normally; plain
    /// paths (absolute or home-relative) are quoted whole.
    static func quoteRemoteDirectory(_ directory: String) -> String {
        guard directory.hasPrefix("~") else { return shellQuote(directory) }
        guard let slash = directory.firstIndex(of: "/") else { return directory }
        let tilde = String(directory[..<slash])
        let rest = String(directory[directory.index(after: slash)...])
        return rest.isEmpty ? directory : "\(tilde)/\(shellQuote(rest))"
    }
}
