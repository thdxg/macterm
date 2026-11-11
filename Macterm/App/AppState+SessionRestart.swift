import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState+SessionRestart")

/// Restart Session (design/002, option A): a session keeps the build that
/// started it, so after an update some tabs run an older build. The tab
/// shows a badge, and this command gives each such session a new shell of
/// the new build, in the same folder. It ends the old shell, so it runs
/// only when the user asks, and it asks first when a program runs.
extension AppState {
    /// The panes of `tab` whose session runs an older build.
    func outdatedPanes(in tab: TerminalTab) -> [Pane] {
        tab.splitRoot.allPanes().filter { !$0.isRemote && outdatedSessions.contains($0.sessionName) }
    }

    /// Whether a session of `tab` runs an older build. The sidebar badge.
    func tabRunsOlderSession(_ tab: TerminalTab) -> Bool {
        !outdatedSessions.isEmpty && !outdatedPanes(in: tab).isEmpty
    }

    /// Restart the older sessions of a tab. A busy pane (a program in front)
    /// asks first: the restart ends that program.
    func requestRestartSessions(tabID: UUID, projectID: UUID) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.id == tabID }) else { return }
        let panes = outdatedPanes(in: tab)
        guard !panes.isEmpty else { return }
        guard panes.contains(where: paneNeedsConfirmClose) else {
            restartSessions(tabID: tabID, projectID: projectID)
            return
        }
        present(PendingDialog(
            kind: .restartSessions(tabID: tabID, projectID: projectID),
            title: String(localized: "Restart running processes?"),
            message: String(localized: "A process is still running in this tab. Restarting the session ends it."),
            confirmTitle: String(localized: "Restart"),
            host: .mainWindow
        ) { [weak self] in self?.restartSessions(tabID: tabID, projectID: projectID) })
    }

    /// Replace each older pane of the tab with a new pane in the folder
    /// where the old shell is. The tab keeps its shape, focus and zoom. The
    /// old session ends with its shell.
    func restartSessions(tabID: UUID, projectID: UUID) {
        guard let tab = workspaces[projectID]?.tabs.first(where: { $0.id == tabID }) else { return }
        let olds = outdatedPanes(in: tab)
        guard !olds.isEmpty else { return }
        // Panes that show one session (a `pane mirror` pair) get one new
        // session, shown by the same number of panes.
        var replacements: [UUID: Pane] = [:]
        var fresh: [String: Pane] = [:]
        for old in olds {
            if let owner = fresh[old.sessionName] {
                replacements[old.id] = Pane(mirroring: owner)
            } else {
                let pane = Pane(
                    projectPath: old.liveLocalWorkingDirectory() ?? old.projectPath,
                    projectID: old.projectID,
                    sessionSlug: old.sessionSlug
                )
                fresh[old.sessionName] = pane
                replacements[old.id] = pane
            }
        }
        tab.splitRoot = tab.splitRoot.replacing(replacements)
        if let focused = tab.focusedPaneID, let new = replacements[focused] { tab.focusedPaneID = new.id }
        if let zoomed = tab.zoomedPaneID, let new = replacements[zoomed] { tab.zoomedPaneID = new.id }
        logger.info("restarting \(olds.count, privacy: .public) older session(s)")
        for old in olds {
            old.destroySurface()
            outdatedSessions.remove(old.sessionName)
        }
        for name in Set(olds.map(\.sessionName)) {
            olds.first { $0.sessionName == name }?.killPersistentSession(using: zmx)
        }
        pruneSessionLeaders()
        for pane in replacements.values {
            warmIfUnrendered(pane, in: tab)
        }
        saveWorkspaces()
    }
}
