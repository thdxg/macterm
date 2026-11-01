import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ScratchTabs")

/// Scratch tabs (#665): a workspace below the projects, keyed by the fixed
/// `ScratchTabs.projectID` sentinel. It holds ordinary tabs that belong to no
/// project.
///
/// The rules, in one place:
/// - The workspace is a plain `Workspace`. Selection, per-window tab
///   selection, mirrors, moves, merges and reorders all take the generic
///   path. `ensureWorkspace` is the one place that treats it specially: it
///   starts EMPTY, because the path-taking init would spawn a tab that
///   nobody asked for.
/// - Closing a scratch tab is a close, not an unload. Nothing declares a scratch
///   tab outside the workspace snapshot, and a dead one leaves no row.
/// - The snapshot restores it like a project workspace
///   (`WorkspaceSerializer.restore` counts the sentinel as valid), so its
///   sessions are claims for the orphan sweep from the first launch on.
/// - A move into the workspace is a plain `moveTab` with the home directory
///   as `destPath`. A move out of it, to a project or to the pinned
///   workspace, is the same move or a pin.
extension AppState {
    // MARK: - Queries

    var scratchWorkspace: Workspace? { workspaces[ScratchTabs.projectID] }

    /// Whether the sidebar has scratch rows to draw.
    var hasScratchTabs: Bool { !(scratchWorkspace?.tabs.isEmpty ?? true) }

    func ensureScratchWorkspace() {
        if workspaces[ScratchTabs.projectID] == nil {
            workspaces[ScratchTabs.projectID] = Workspace(
                projectID: ScratchTabs.projectID, tabs: [], activeTabID: nil
            )
        }
    }

    // MARK: - Selection

    /// Select the scratch workspace itself (the sidebar's Scratch Tabs header),
    /// in `window`, or app-wide when none is given. The generic project
    /// selection serves: `ensureWorkspace` knows the sentinel, and the sweep
    /// and the remote reconnect have nothing to do for a local workspace.
    func selectScratchTabs(in window: WindowState? = nil) {
        selectProject(ScratchTabs.project, in: window)
        // The workspace can be restored with no selection (every tab was
        // closed, then a tab was created from the CLI with `--no-focus`);
        // a nil active tab renders a blank detail view.
        if let ws = scratchWorkspace, ws.activeTabID == nil {
            ws.activeTabID = ws.tabs.first?.id
        }
    }

    /// Select a scratch tab from a keyboard cycle or the CLI: the workspace
    /// first, then the tab.
    func selectScratchTab(_ tabID: UUID) {
        guard let ws = scratchWorkspace, ws.tabs.contains(where: { $0.id == tabID }) else { return }
        activeProjectID = ScratchTabs.projectID
        _ = ws.selectTab(tabID)
        warmFocusedProject()
        saveWorkspaces()
    }

    // MARK: - Creation and moves

    /// A new scratch tab: a shell in home, or in the focused scratch pane's
    /// directory under `tab-inherit-working-directory`. With `focus` the
    /// workspace becomes the active one first, so the key window follows
    /// the new tab as it does for Cmd+T in a project.
    @discardableResult
    func createScratchTab(command: String? = nil, env: [String: String]? = nil, focus: Bool = true) -> UUID? {
        ensureScratchWorkspace()
        if focus, activeProjectID != ScratchTabs.projectID {
            activeProjectID = ScratchTabs.projectID
        }
        let id = createTab(projectID: ScratchTabs.projectID, projects: [], command: command, env: env, focus: focus)
        logger.info("createScratchTab: \(id?.uuidString ?? "nil", privacy: .public)")
        return id
    }

    /// Move a project tab out of its project. Shells intact; the tab keeps
    /// its own working directory. `toIndex` is the slot among the scratch
    /// rows; nil appends.
    func moveTabToScratchTabs(_ tabID: UUID, from sourceProjectID: UUID, toIndex: Int? = nil) {
        guard sourceProjectID != ScratchTabs.projectID else { return }
        moveTab(tabID, from: sourceProjectID, to: ScratchTabs.projectID, destPath: ScratchTabs.fallbackRoot, toIndex: toIndex)
    }
}
