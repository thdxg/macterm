import Foundation

/// Where a project lives: a local directory, or a directory on a remote host
/// reached over SSH. Parsed from a single scp-style string — the `path:` of a
/// central project file (and, in a later stage, `Project.path`):
///
///     /Users/me/dev/api        → local
///     ~/dev/api                → local
///     devbox:~/dev/api         → remote (host from ~/.ssh/config)
///     deploy@10.0.0.5:/srv/app → remote with explicit user
///
/// The grammar is scp's: a colon *before the first slash* marks a remote
/// `[user@]host:dir`; anything absolute or `~`-prefixed is local. Relative
/// local paths are invalid (there's no cwd to resolve them against), as are
/// empty host/dir parts. Port and identity aren't expressible here by design —
/// use an ssh-config alias for those. IPv6 literals (`[::1]:dir`) aren't
/// supported; alias them in ssh config too.
enum ProjectPath: Equatable {
    case local(String)
    case remote(user: String?, host: String, directory: String)

    /// Parse an scp-style path string. Returns nil for anything that is
    /// neither a valid local path (absolute or `~`-prefixed) nor a well-formed
    /// remote spec.
    static func parse(_ raw: String) -> ProjectPath? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // scp rule: a colon before the first slash → remote spec.
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains("/")
        {
            let userHost = trimmed[..<colon]
            let directory = String(trimmed[trimmed.index(after: colon)...])
            guard !directory.isEmpty else { return nil }

            // `user@host` splits at the LAST `@` (usernames may contain `@`
            // in principle; hosts never do). A host starting with `~` is
            // rejected: scp would accept it, but `~foo:bar` is far likelier a
            // mistyped local path than a host literally named `~foo`.
            if let at = userHost.lastIndex(of: "@") {
                let user = String(userHost[..<at])
                let host = String(userHost[userHost.index(after: at)...])
                guard !user.isEmpty, !host.isEmpty, !host.hasPrefix("~") else { return nil }
                return .remote(user: user, host: host, directory: directory)
            }
            guard !userHost.isEmpty, !userHost.hasPrefix("~") else { return nil }
            return .remote(user: nil, host: String(userHost), directory: directory)
        }

        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        return .local(trimmed)
    }

    /// The user's home directory, `$HOME`-first. `NSHomeDirectory()` and
    /// `expandingTildeInPath` resolve via the user record and IGNORE the env
    /// var, which would defeat the benchmark harness's throwaway-home
    /// isolation; the login session sets `$HOME` for normal launches, so
    /// env-first behaves identically outside the harness.
    static var currentHome: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    /// Inverse of the `~` expansion in `canonicalLocal`, for *writing* a
    /// local path: the current home prefix contracts to `~` so saved project
    /// files stay valid when `~/.config/macterm` syncs (dotfiles) to a
    /// machine with a different user name. Paths outside home pass through.
    static func homeContracted(_ path: String) -> String {
        let home = currentHome
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Canonical form of a *local* path for identity comparisons (matching a
    /// project file's `path:` against a project's directory): tilde expanded
    /// (against `currentHome`), `.`/`..` segments standardized, trailing
    /// slash stripped. Symlinks are deliberately NOT resolved — two paths the
    /// user treats as distinct must stay distinct even when one links to the
    /// other.
    static func canonicalLocal(_ path: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = currentHome
        } else if expanded.hasPrefix("~/") {
            expanded = currentHome + expanded.dropFirst(1)
        } else if expanded.hasPrefix("~") {
            // `~user/...` — no env override applies; defer to Foundation.
            expanded = (expanded as NSString).expandingTildeInPath
        }
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    /// Convenience for call sites holding a raw path string (`Project.path`,
    /// `Pane.projectPath` — the remote spec travels and persists as a string).
    static func isRemote(_ raw: String) -> Bool {
        if case .remote = parse(raw) { return true }
        return false
    }

    /// The parsed spec when `raw` is a remote path; nil for local or invalid.
    /// The typed input for `RemoteSpawn` call sites.
    static func remote(from raw: String) -> ProjectPath? {
        guard let parsed = parse(raw), case .remote = parsed else { return nil }
        return parsed
    }

    /// Compose a remote `path:` string from the New Remote Project sheet's
    /// fields (`[user@]host` + directory), validating through the parser.
    /// nil when the pair doesn't form a well-formed remote spec.
    static func composeRemote(host: String, directory: String) -> String? {
        let composed = host.trimmingCharacters(in: .whitespaces)
            + ":"
            + directory.trimmingCharacters(in: .whitespaces)
        return isRemote(composed) ? composed : nil
    }

    /// Whether two raw path strings identify the same project location.
    /// Locals compare canonically; remotes compare structurally (same
    /// user/host/directory after parsing). A local never equals a remote,
    /// and unparseable strings match nothing.
    static func matches(_ a: String, _ b: String) -> Bool {
        switch (parse(a), parse(b)) {
        case let (.local(pa), .local(pb)):
            canonicalLocal(pa) == canonicalLocal(pb)
        case let (.remote(ua, ha, da), .remote(ub, hb, db)):
            ua == ub && ha == hb && da == db
        default:
            false
        }
    }
}
