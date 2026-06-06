import CoreGraphics
import Foundation

/// Builds a live `SplitNode` tree from a declarative `LayoutFile`. Mirrors
/// `WorkspaceSerializer.restoreNode`, but resolves each leaf's cwd/shell and
/// carries the declared `run` command onto the `Pane` so it launches the
/// process and so `LayoutReconciler` can later match the pane by identity.
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

    /// Construct a `Pane` for a declared leaf, resolving cwd and shell.
    /// Shell precedence: per-pane `shell` → file-level `defaultShell` → nil
    /// (leaving `Pane`/libghostty to resolve the ghostty-config / login shell).
    static func makePane(
        _ pane: LayoutPane,
        projectRoot: String,
        projectID: UUID,
        defaultShell: String?
    ) -> Pane {
        Pane(
            projectPath: resolveCwd(pane.cwd, projectRoot: projectRoot),
            projectID: projectID,
            command: (pane.run?.isEmpty == false) ? pane.run : nil,
            shell: pane.shell ?? defaultShell
        )
    }

    /// Recursively build a `SplitNode` from a declared `LayoutNode`.
    static func buildNode(
        _ node: LayoutNode,
        projectRoot: String,
        projectID: UUID,
        defaultShell: String?
    ) -> SplitNode {
        switch node {
        case let .pane(p):
            .pane(makePane(p, projectRoot: projectRoot, projectID: projectID, defaultShell: defaultShell))
        case let .split(b):
            .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.resolvedRatio),
                first: buildNode(b.first, projectRoot: projectRoot, projectID: projectID, defaultShell: defaultShell),
                second: buildNode(b.second, projectRoot: projectRoot, projectID: projectID, defaultShell: defaultShell)
            ))
        }
    }

    /// Build the full set of tabs declared by a layout file.
    static func buildTabs(
        _ file: LayoutFile,
        projectRoot: String,
        projectID: UUID
    ) -> [TerminalTab] {
        file.tabs.map { tab in
            let root = buildNode(tab.layout, projectRoot: projectRoot, projectID: projectID, defaultShell: file.shell)
            return TerminalTab(id: UUID(), splitRoot: root, focusedPaneID: root.allPanes().first?.id, customTitle: tab.name)
        }
    }
}
