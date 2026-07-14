import Foundation

/// Serializes a live workspace back into a declarative `LayoutFile` — the
/// `save` direction, inverse of `LayoutBuilder`. Mirrors
/// `WorkspaceSerializer.snapshotNode`: walks the live split tree and emits
/// `LayoutNode`s, recording each pane's cwd (project-relative) and declared
/// `run` command.
@MainActor
enum LayoutSerializer {
    /// Build a `LayoutFile` from a workspace's tabs. `liveCommand` returns a
    /// pane's current foreground command (saved as its `run`); `liveShell`
    /// returns the pane's foreground shell when it's sitting in one (saved as
    /// `shell:`). Both default to `ProcessInspector`, injected by tests.
    static func layout(
        for workspace: Workspace,
        projectName: String,
        projectRoot: String,
        liveCommand: (Pane) -> String? = { ProcessInspector.runningCommand(forPane: $0) },
        liveShell: (Pane) -> String? = { ProcessInspector.runningShell(forPane: $0) }
    ) -> LayoutFile {
        LayoutFile(
            name: projectName,
            tabs: workspace.tabs.map { tab in
                LayoutTab(
                    name: tab.customTitle,
                    layout: node(tab.splitRoot, projectRoot: projectRoot, liveCommand: liveCommand, liveShell: liveShell)
                )
            }
        )
    }

    // MARK: - Tree walk

    private static func node(
        _ node: SplitNode,
        projectRoot: String,
        liveCommand: (Pane) -> String?,
        liveShell: (Pane) -> String?
    ) -> LayoutNode {
        switch node {
        case let .pane(p):
            // Prefer the shell's live cwd over the pane's original path, same as
            // WorkspaceSerializer.snapshotNode, so a saved layout reflects where
            // the user actually navigated. Remote panes (#104) record their
            // scp-style `projectPath` verbatim — their `currentPwd` is a
            // remote-filesystem path with no host prefix, and live-cwd capture
            // is disabled for remote panes by design.
            let livePath = p.isRemote ? p.projectPath : (p.nsView?.currentPwd ?? p.projectPath)
            // `run`: whatever the pane is *currently* running (its live
            // foreground command), NOT the command it was spawned with — a pane
            // launched with `btop` that the user has since quit is idle and
            // should save no `run`. nil → idle / nothing to record.
            //
            // `shell`: when the pane is sitting in a shell, save that shell's
            // path — so a pane the user dropped into a different shell (e.g.
            // `zsh` launched from `nu`) reopens in it. `run` and `shell` are
            // mutually exclusive: the foreground is either a shell or a command.
            return .pane(LayoutPane(
                cwd: relativePath(livePath, to: projectRoot),
                run: liveCommand(p),
                shell: liveShell(p)
            ))
        case let .split(b):
            return .split(LayoutBranch(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: self.node(b.first, projectRoot: projectRoot, liveCommand: liveCommand, liveShell: liveShell),
                second: self.node(b.second, projectRoot: projectRoot, liveCommand: liveCommand, liveShell: liveShell)
            ))
        }
    }

    /// Express an absolute path relative to the project root when it's inside
    /// the root; otherwise keep it absolute. The project root itself becomes
    /// nil (the builder treats nil cwd as "the project root").
    static func relativePath(_ path: String, to root: String) -> String? {
        // A remote root (#104) is an scp-style spec, not a local filesystem
        // path — running it through `URL(fileURLWithPath:)` standardizes it
        // against the process cwd and yields garbage. Remote panes record
        // their identity verbatim (see `node`), so treat any remote path as
        // pure strings: return nil when it equals the root, else the path
        // itself (LayoutBuilder.resolveCwd handles remote cwds symmetrically).
        if ProjectPath.isRemote(path) || ProjectPath.isRemote(root) {
            return path == root ? nil : path
        }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        if standardizedPath == standardizedRoot { return nil }
        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        if standardizedPath.hasPrefix(rootPrefix) {
            return "./" + String(standardizedPath.dropFirst(rootPrefix.count))
        }
        return standardizedPath
    }
}
