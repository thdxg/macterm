import Foundation

/// Helpers for turning a declared `LayoutPane` into a live `Pane` — resolving
/// its working directory and shell and carrying the declared `run` command so
/// the pane launches it. `LayoutReconciler` uses these to build the panes it
/// spawns; it does its own tree assembly so it can reuse matched live panes.
@MainActor
enum LayoutBuilder {
    /// Resolve a pane's working directory against the project root. A nil/empty
    /// `cwd` resolves to the project root; `~` is expanded; absolute paths pass
    /// through; everything else is treated as relative to the root.
    ///
    /// A REMOTE root (#104) resolves as pure strings — no local filesystem
    /// semantics apply: `~`/absolute declared cwds are remote-home/-absolute
    /// (never expanded against the local home), relative ones join the root's
    /// directory, and the result keeps the `[user@]host:` prefix so the pane
    /// stays a remote pane.
    static func resolveCwd(_ cwd: String?, projectRoot: String) -> String {
        guard let cwd, !cwd.isEmpty else { return projectRoot }
        if case let .remote(user, host, directory)? = ProjectPath.parse(projectRoot) {
            let resolved: String = if cwd.hasPrefix("/") || cwd.hasPrefix("~") {
                cwd
            } else if directory.hasSuffix("/") {
                directory + cwd
            } else {
                directory + "/" + cwd
            }
            let userPrefix = user.map { "\($0)@" } ?? ""
            return "\(userPrefix)\(host):\(resolved)"
        }
        let expanded = expandTilde(cwd)
        if expanded.hasPrefix("/") { return canonicalizeLocal(expanded) }
        return URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
    }

    /// Expand a leading `~`/`~/` against `$HOME` (env-first, honoring the
    /// benchmark's throwaway home — unlike `expandingTildeInPath`, which
    /// resolves via the user record and ignores `$HOME`). `~user` is left to
    /// `expandingTildeInPath` since only the password DB can resolve it.
    private static func expandTilde(_ path: String) -> String {
        if path == "~" { return ProjectPath.currentHome }
        if path.hasPrefix("~/") { return ProjectPath.currentHome + path.dropFirst(1) }
        return (path as NSString).expandingTildeInPath
    }

    /// Standardize a local absolute path the same way `resolveCwd` produces its
    /// relative-join output, so a live pane's raw OSC-7 `currentPwd` and a
    /// declared cwd compare equal in `LayoutReconciler` (e.g. `/a/b/` == `/a/b`).
    /// Remote specs pass through untouched (no local filesystem semantics).
    static func canonicalizeLocal(_ path: String) -> String {
        guard !ProjectPath.isRemote(path) else { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Construct a `Pane` for a declared leaf, resolving cwd. The pane's `shell`
    /// is used as-is; when nil, `Pane`/libghostty resolves the ghostty-config /
    /// login shell.
    static func makePane(
        _ pane: LayoutPane,
        projectRoot: String,
        projectID: UUID
    ) -> Pane {
        Pane(
            projectPath: resolveCwd(pane.cwd, projectRoot: projectRoot),
            projectID: projectID,
            command: (pane.run?.isEmpty == false) ? pane.run : nil,
            shell: pane.shell
        )
    }
}
