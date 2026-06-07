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
    static func resolveCwd(_ cwd: String?, projectRoot: String) -> String {
        guard let cwd, !cwd.isEmpty else { return projectRoot }
        let expanded = (cwd as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
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
