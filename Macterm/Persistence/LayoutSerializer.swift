import Foundation

/// Serializes a live workspace back into a declarative `LayoutFile` — the
/// `save` direction, inverse of `LayoutBuilder`. Mirrors
/// `WorkspaceSerializer.snapshotNode`: walks the live split tree and emits
/// `LayoutNode`s, recording each pane's cwd (project-relative) and declared
/// `run` command.
@MainActor
enum LayoutSerializer {
    /// Build a `LayoutFile` from a workspace's tabs. `liveCommand` returns a
    /// pane's current foreground command (saved as its `run`); defaults to
    /// `ProcessInspector.runningCommand`, injected by tests.
    static func layout(
        for workspace: Workspace,
        projectName: String,
        projectRoot: String,
        liveCommand: (Pane) -> String? = { ProcessInspector.runningCommand(forPane: $0) }
    ) -> LayoutFile {
        LayoutFile(
            name: projectName,
            tabs: workspace.tabs.map { tab in
                LayoutTab(name: tab.customTitle, layout: node(tab.splitRoot, projectRoot: projectRoot, liveCommand: liveCommand))
            }
        )
    }

    /// Write a workspace out to its project's `.macterm/layout.yaml`, creating
    /// the `.macterm` directory if needed.
    static func write(
        _ workspace: Workspace,
        projectName: String,
        projectRoot: String,
        liveCommand: (Pane) -> String? = { ProcessInspector.runningCommand(forPane: $0) }
    ) throws {
        let file = layout(for: workspace, projectName: projectName, projectRoot: projectRoot, liveCommand: liveCommand)
        let url = LayoutFile.url(forProjectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.yaml().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tree walk

    private static func node(_ node: SplitNode, projectRoot: String, liveCommand: (Pane) -> String?) -> LayoutNode {
        switch node {
        case let .pane(p):
            // Prefer the shell's live cwd over the pane's original path, same as
            // WorkspaceSerializer.snapshotNode, so a saved layout reflects where
            // the user actually navigated.
            let livePath = p.nsView?.currentPwd ?? p.projectPath
            // `run`: whatever the pane is *currently* running (its live
            // foreground command), NOT the command it was spawned with — a pane
            // launched with `btop` that the user has since quit is idle and
            // should save no `run`. nil → idle / nothing to record.
            //
            // `shell` is deliberately NOT persisted by save — the user
            // hand-authors `shell:` when they want a specific shell. Saving it
            // would bake in whatever shell happened to be active.
            return .pane(LayoutPane(
                cwd: relativePath(livePath, to: projectRoot),
                run: liveCommand(p),
                shell: nil
            ))
        case let .split(b):
            return .split(LayoutBranch(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: self.node(b.first, projectRoot: projectRoot, liveCommand: liveCommand),
                second: self.node(b.second, projectRoot: projectRoot, liveCommand: liveCommand)
            ))
        }
    }

    /// Express an absolute path relative to the project root when it's inside
    /// the root; otherwise keep it absolute. The project root itself becomes
    /// nil (the builder treats nil cwd as "the project root").
    static func relativePath(_ path: String, to root: String) -> String? {
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
