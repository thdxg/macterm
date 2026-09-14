import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState+QuickTerminal")

/// The quick terminal's place in persistence.
///
/// The panel's tab lives in `QuickTerminalService.shared.splitState`, outside
/// every workspace, so none of the machinery that keeps workspace panes alive
/// across a quit reached it: it was never snapshotted, its sessions were
/// killed in `applicationWillTerminate`, and a busy pane in it was the one
/// thing a persistence-active quit still confirmed. This extension gives it
/// the same three guarantees a workspace pane has — its tab rides in the
/// snapshot (`WorkspacesFile.quickTerminal`), the launch restore hands the
/// tab back so the panel reattaches its sessions, and the orphan reaper
/// counts its sessions as claimed — which is what lets quit be silent.
///
/// `AppState` reaches the state through `adoptQuickTerminal`, once: the
/// panel's singleton by default, or one handed to `init` by tests so a
/// restore never writes into the shared instance. Adoption is also where the
/// state's `onStructureChange` is pointed at `saveWorkspaces`, so a split or
/// close in the panel persists at once, as a workspace mutation does, rather
/// than only at quit — gated on the launch restore having run, like
/// `persistWindows`, because `workspaces` is empty until then and a save
/// would write that emptiness over the very file the restore is about to
/// read (the panel's hotkey works from the first moment of launch).
extension AppState {
    /// The adopted split state, adopting the panel's singleton on first use.
    var quickTerminal: QuickTerminalSplitState {
        if let adopted = adoptedQuickTerminal { return adopted }
        let state = QuickTerminalService.shared.splitState
        adoptQuickTerminal(state)
        return state
    }

    /// Make `state` the quick terminal this AppState persists, and route its
    /// structural changes into the snapshot.
    func adoptQuickTerminal(_ state: QuickTerminalSplitState) {
        adoptedQuickTerminal = state
        state.onStructureChange = { [weak self] in
            guard let self, self.hasRestoredSelection else { return }
            self.saveWorkspaces()
        }
    }

    /// Hand the persisted tab back to the panel. A nil snapshot (a file from
    /// before the section existed) leaves the fresh tab the state was born
    /// with; a snapshot arriving after the panel has already been shown this
    /// run is declined by the state itself, which logs here so a session that
    /// then goes unclaimed can be traced.
    func restoreQuickTerminal(_ snapshot: TabSnapshot?) {
        guard let snapshot else { return }
        if !quickTerminal.restore(from: snapshot) {
            logger.info("quick terminal already shown before restore; keeping its live tab")
        }
    }

    /// The quick terminal's tab as the snapshot carries it.
    func quickTerminalSnapshot() -> TabSnapshot {
        WorkspaceSerializer.snapshotTab(quickTerminal.tab)
    }

    /// The sessions the quick terminal's panes hold — claims for the orphan
    /// reaper, since a restored pane attaches only when the panel is shown.
    func quickTerminalSessionNames() -> Set<String> {
        Set(quickTerminal.tab.splitRoot.allPanes().map(\.sessionName))
    }
}
