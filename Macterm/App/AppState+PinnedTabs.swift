import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PinnedTabs")

/// Pinned tabs: a special workspace above the projects, keyed by the
/// fixed `PinnedTabs.projectID` sentinel — deliberately NOT a `ProjectStore`
/// row. Each pinned tab is a `PinnedTabRecord`: a durable declaration
/// (splits + per-pane cwd/run/shell) plus, while loaded, an ordinary live
/// `TerminalTab` in the sentinel workspace.
///
/// The rules, in one place:
/// - Pin = `moveTab` into the sentinel (declaration captured, origin stamped);
///   Unpin = `moveTab` back to the origin project. Both are moves — sessions
///   are never killed by pinning state changes. "Remove from Pinned" is the
///   one killing action (busy-confirmed).
/// - CLOSING a pinned tab is an UNLOAD, never a removal: sessions end, the
///   record — and its `pinned.yaml` entry — stays as a dimmed row, and the
///   next launch eager-starts it again. The same unload happens when a tab's
///   own sessions die (`paneProcessExited`). Selecting an unloaded record
///   rebuilds the tab from its declaration, re-running its `run:` commands.
/// - `pinned.yaml` (see `PinnedLayoutStore`) mirrors the records and is
///   authoritative for membership at launch. It is rewritten on membership
///   changes, on a debounced pinned-pane foreground change
///   (`notePinnedForegroundChangesIfNeeded`), and at quit; external edits are
///   absorbed before every write, never clobbered.
extension AppState {
    // MARK: - Queries

    var pinnedWorkspace: Workspace? { workspaces[PinnedTabs.projectID] }

    func isPinnedTabLoaded(_ id: UUID) -> Bool {
        pinnedWorkspace?.tabs.contains { $0.id == id } ?? false
    }

    func pinnedRecord(_ id: UUID) -> PinnedTabRecord? {
        pinnedRecords.first { $0.id == id }
    }

    func ensurePinnedWorkspace() {
        if workspaces[PinnedTabs.projectID] == nil {
            // Empty on purpose — `Workspace(projectID:projectPath:)` would
            // spawn an initial tab the user never pinned.
            workspaces[PinnedTabs.projectID] = Workspace(
                projectID: PinnedTabs.projectID, tabs: [], activeTabID: nil
            )
        }
    }

    // MARK: - Pin / Unpin

    /// Move a project tab into the pinned workspace, capturing its live
    /// layout (cwd/run/shell per pane — the same seams Save Layout reads) as
    /// the record's declaration. `toRecordIndex` is the sidebar slot among
    /// the pinned rows (records, loaded or not); nil appends.
    func pinTab(_ tabID: UUID, fromProject sourceProjectID: UUID, toRecordIndex: Int? = nil) {
        guard sourceProjectID != PinnedTabs.projectID,
              pinnedRecord(tabID) == nil,
              let source = workspaces[sourceProjectID],
              let tab = source.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.info("pinTab: \(tabID, privacy: .public) from=\(sourceProjectID, privacy: .public)")
        let declaration = LayoutSerializer.pinnedDeclaration(for: tab)
        ensurePinnedWorkspace()
        guard let dest = pinnedWorkspace else { return }
        let recordIndex = min(max(toRecordIndex ?? pinnedRecords.count, 0), pinnedRecords.count)
        source.closeTab(tabID)
        dest.adoptTab(tab, at: liveIndex(forRecordIndex: recordIndex))
        for pane in tab.splitRoot.allPanes() {
            pane.rebind(projectID: PinnedTabs.projectID)
        }
        let record = PinnedTabRecord(id: tabID, declaration: declaration, originProjectID: sourceProjectID)
        pinnedRecords.insert(record, at: recordIndex)
        activeProjectID = PinnedTabs.projectID
        saveWorkspaces()
    }

    /// Unpin: a LOADED tab moves back to its origin project (falling back to
    /// the first project) — a move, never a kill. An UNLOADED record has no
    /// live tab to move; unpinning it just forgets the declaration.
    func unpinTab(_ tabID: UUID, projects: [Project]) {
        guard let record = pinnedRecord(tabID) else { return }
        guard isPinnedTabLoaded(tabID) else {
            logger.info("unpinTab: forgetting unloaded record \(tabID, privacy: .public)")
            removePinnedRecord(forTab: tabID)
            saveWorkspaces()
            return
        }
        let dest = projects.first { $0.id == record.originProjectID } ?? projects.first
        guard let dest else {
            presentToast("Can’t unpin", subtitle: "Add a project to move the tab into first")
            return
        }
        // moveTab removes the record (its unpin hook) and rewrites the file.
        moveTab(tabID, from: PinnedTabs.projectID, to: dest.id, destPath: dest.path)
    }

    /// Unpin a record that has NO live tab (its sessions died) into a
    /// project — the drag-an-unloaded-row-out path, where the drop names the
    /// destination. A pending live snapshot (the launch race) restores there;
    /// otherwise the declaration spawns there, `run:` and all.
    func unpinUnloadedRecord(_ record: PinnedTabRecord, toProject destProjectID: UUID, toIndex: Int? = nil) {
        logger.info("unpinUnloadedRecord: \(record.id, privacy: .public) → \(destProjectID, privacy: .public)")
        let tab: TerminalTab
        if let snapshot = pendingPinnedLiveRestores.removeValue(forKey: record.id) {
            tab = WorkspaceSerializer.restoreTab(snapshot, projectID: destProjectID)
        } else if let built = buildDeclaredPinnedTab(record, projectID: destProjectID) {
            tab = built
        } else {
            removePinnedRecord(forTab: record.id)
            saveWorkspaces()
            return
        }
        ensureAdoptableWorkspace(projectID: destProjectID)
        workspaces[destProjectID]?.adoptTab(tab, at: toIndex)
        removePinnedRecord(forTab: record.id)
        activeProjectID = destProjectID
        saveWorkspaces()
    }

    /// Remove a pin ENTIRELY — the record, its `pinned.yaml` entry, and (when
    /// loaded) the live tab with its sessions. The one pinned action that
    /// kills, hence the busy confirmation; for an unloaded record there is
    /// nothing running and it reduces to forgetting the declaration.
    func requestRemovePinnedTab(_ tabID: UUID) {
        let busy = pinnedWorkspace?.tabs
            .first { $0.id == tabID }?
            .splitRoot.allPanes()
            .contains(where: \.needsConfirmClose) ?? false
        if busy {
            pendingRemovePinnedTab = AppState.PendingRemovePinnedTab(tabID: tabID)
            return
        }
        removePinnedTab(tabID)
    }

    func confirmPendingRemovePinnedTab() {
        guard let pending = pendingRemovePinnedTab else { return }
        pendingRemovePinnedTab = nil
        removePinnedTab(pending.tabID)
    }

    func cancelPendingRemovePinnedTab() {
        pendingRemovePinnedTab = nil
    }

    func removePinnedTab(_ tabID: UUID) {
        guard pinnedRecord(tabID) != nil else { return }
        logger.info("removePinnedTab: \(tabID, privacy: .public)")
        if let ws = pinnedWorkspace, let tab = ws.tabs.first(where: { $0.id == tabID }) {
            for pane in tab.splitRoot.allPanes() {
                pane.killPersistentSession(using: zmx)
                pane.destroySurface()
            }
            ws.closeTab(tabID)
        }
        removePinnedRecord(forTab: tabID)
        saveWorkspaces()
    }

    /// Drop a record after its tab left the pinned workspace (a moveTab /
    /// merge out). The workspace side is the caller's job.
    func removePinnedRecord(forTab tabID: UUID) {
        guard pinnedRecords.contains(where: { $0.id == tabID }) else { return }
        pinnedRecords.removeAll { $0.id == tabID }
        pendingPinnedLiveRestores.removeValue(forKey: tabID)
    }

    /// Reorder a pinned row to a drop offset in RECORD space (pre-removal
    /// coordinates, like `Workspace.moveTab`), then realign the live tab
    /// order to match.
    func reorderPinnedTab(_ tabID: UUID, toIndex destination: Int) {
        guard let from = pinnedRecords.firstIndex(where: { $0.id == tabID }) else { return }
        let to = Workspace.resolvedMoveIndex(from: from, toDropOffset: destination, count: pinnedRecords.count)
        guard to != from else { return }
        let record = pinnedRecords.remove(at: from)
        pinnedRecords.insert(record, at: to)
        alignPinnedWorkspaceOrder()
        saveWorkspaces()
    }

    /// The CLI's `tab move` computes its offset against the LIVE tab list;
    /// translate it into record space so the sidebar rows and `pinned.yaml`
    /// follow the reorder instead of silently disagreeing with it.
    func reorderPinnedLiveTab(_ tabID: UUID, toLiveIndex destination: Int) {
        guard let ws = pinnedWorkspace else { return }
        let recordDest: Int = if destination >= ws.tabs.count {
            pinnedRecords.count
        } else {
            pinnedRecords.firstIndex { $0.id == ws.tabs[max(destination, 0)].id } ?? pinnedRecords.count
        }
        reorderPinnedTab(tabID, toIndex: recordDest)
    }

    /// Separate a pane into its own PINNED tab at a sidebar slot. The slot is
    /// in RECORD space (what the pinned ForEach's insertion offset counts —
    /// unloaded rows included); `separatePane` speaks live-tab indices, so
    /// this owns the conversion and then pins the auto-created record at the
    /// requested slot.
    func separatePaneIntoPinned(_ paneID: UUID, atRecordIndex recordIndex: Int?) {
        ensurePinnedWorkspace()
        let slot = recordIndex.map { min(max($0, 0), pinnedRecords.count) }
        let before = Set(pinnedRecords.map(\.id))
        separatePane(
            paneID,
            toProject: PinnedTabs.projectID,
            destPath: PinnedTabs.fallbackRoot,
            at: slot.map { liveIndex(forRecordIndex: $0) }
        )
        // `saveWorkspaces` (inside separatePane) auto-recorded the new tab at
        // a slot derived from its LIVE position; move the record to the slot
        // the drop actually named (they differ when unloaded rows precede it).
        guard let slot,
              let newID = pinnedRecords.map(\.id).first(where: { !before.contains($0) }),
              let from = pinnedRecords.firstIndex(where: { $0.id == newID })
        else { return }
        let to = min(slot, pinnedRecords.count - 1)
        guard to != from else { return }
        let record = pinnedRecords.remove(at: from)
        pinnedRecords.insert(record, at: to)
        alignPinnedWorkspaceOrder()
        saveWorkspaces()
    }

    // MARK: - Selection / loading

    /// Select the pinned workspace itself (the sidebar's pinned header).
    func selectPinnedProject() {
        ensurePinnedWorkspace()
        activeProjectID = PinnedTabs.projectID
        // The pinned workspace can be restored with no selection (only
        // records persist one); a nil activeTab renders a blank detail view.
        if let ws = pinnedWorkspace, ws.activeTabID == nil {
            ws.activeTabID = ws.tabs.first?.id
        }
        warmFocusedProject()
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    /// Select a pinned row. Loaded → plain tab selection. Restored-but-not-
    /// materialized → materialize its live snapshot now (reattach; `zmx
    /// attach` upserts if it died in the race window). Unloaded → rebuild
    /// from the declaration, re-running its `run:` commands.
    func selectPinnedTab(_ tabID: UUID) {
        guard pinnedRecord(tabID) != nil else { return }
        ensurePinnedWorkspace()
        guard let ws = pinnedWorkspace else { return }
        activeProjectID = PinnedTabs.projectID
        if !isPinnedTabLoaded(tabID) {
            if let snapshot = pendingPinnedLiveRestores.removeValue(forKey: tabID) {
                let tab = WorkspaceSerializer.restoreTab(snapshot, projectID: PinnedTabs.projectID)
                insertPinnedTabAligned(tab)
            } else if let record = pinnedRecord(tabID) {
                loadPinnedTab(record)
            }
        }
        ws.selectTab(tabID)
        warmFocusedProject()
        saveWorkspaces()
    }

    /// Rebuild an unloaded record's live tab from its declaration — a
    /// pure-spawn reconcile plan (no live workspace → nothing to destroy),
    /// so declared `run:` commands launch via `initial_input`.
    private func loadPinnedTab(_ record: PinnedTabRecord) {
        logger.info("loadPinnedTab: restoring \(record.id, privacy: .public) from declaration")
        guard let tab = buildDeclaredPinnedTab(record) else { return }
        insertPinnedTabAligned(tab)
    }

    /// Construct (but don't insert) a fresh live tab from a record's
    /// declaration. Shared by restore-on-selection, the eager launch load,
    /// and the unpin-an-unloaded-record drag (which spawns into a project).
    /// The pinned PSEUDO-ROOT (`PinnedTabs.pathMarker`) makes
    /// `LayoutBuilder.resolveCwd` treat every leaf cwd as self-contained.
    private func buildDeclaredPinnedTab(
        _ record: PinnedTabRecord,
        projectID: UUID = PinnedTabs.projectID
    ) -> TerminalTab? {
        let layout = LayoutFile(name: nil, tabs: [record.declaration])
        let plan = LayoutReconciler.plan(
            layout: layout,
            workspace: nil,
            projectRoot: PinnedTabs.pathMarker,
            projectID: projectID
        )
        guard let planned = plan.tabs.first else { return nil }
        return TerminalTab(
            id: record.id,
            splitRoot: planned.root,
            focusedPaneID: planned.focusedPaneID,
            customTitle: record.declaration.name
        )
    }

    /// In-project keyboard cycling for the pinned workspace: steps through
    /// the RECORDS (what the sidebar shows), restoring an unloaded row on
    /// landing — not just the loaded tabs.
    func cyclePinnedTab(step: Int) {
        guard pinnedRecords.count > 1 else { return }
        let currentIndex = pinnedWorkspace?.activeTabID
            .flatMap { id in pinnedRecords.firstIndex { $0.id == id } } ?? 0
        let count = pinnedRecords.count
        let next = pinnedRecords[(currentIndex + step + count) % count]
        selectPinnedTab(next.id)
    }

    // MARK: - Session death → unload

    /// The process-exit path (a pane's shell ended on its own), distinct from
    /// the user's close request. For a normal project this is exactly the old
    /// behavior (close the pane, and the tab with its last pane). For a
    /// pinned tab, the LAST pane dying unloads the tab instead: sessions are
    /// gone, surfaces torn down, but the record — and its sidebar row — stay,
    /// and the next selection restores from the declaration.
    func paneProcessExited(_ paneID: UUID, projectID: UUID) {
        guard projectID == PinnedTabs.projectID,
              let ws = pinnedWorkspace,
              let tab = ws.tabs.first(where: { $0.splitRoot.findPane(id: paneID) != nil })
        else {
            requestClosePane(paneID, projectID: projectID)
            return
        }
        if tab.splitRoot.allPanes().count > 1 {
            closePane(paneID, projectID: projectID)
        } else {
            unloadPinnedTab(tab.id)
        }
    }

    /// Tear a pinned tab's live half down (sessions are already dead — the
    /// kill is a safe no-op that also covers a lingering remote daemon),
    /// keeping the record as an unloaded row. Deliberately NOT refreshing the
    /// declaration here: a dead pane reads as idle, and capturing that would
    /// erase the `run:` this record exists to re-run.
    func unloadPinnedTab(_ tabID: UUID) {
        guard let ws = pinnedWorkspace,
              let tab = ws.tabs.first(where: { $0.id == tabID })
        else { return }
        logger.info("unloadPinnedTab: \(tabID, privacy: .public)")
        for pane in tab.splitRoot.allPanes() {
            pane.killPersistentSession(using: zmx)
            pane.destroySurface()
        }
        ws.closeTab(tabID)
        saveWorkspaces()
    }

    // MARK: - Restore / materialize

    /// Rebuild the records from the workspace snapshot. Live tab snapshots
    /// are NOT materialized here — they wait for `materializeRestoredPinnedTabs`
    /// to ask zmx which sessions survived, because `zmx attach` is an upsert:
    /// eagerly restoring a dead session would silently hand the user a bare
    /// shell where the declaration should have re-run its command.
    func restorePinnedState(_ snapshots: [PinnedTabSnapshot], activeTabID: UUID? = nil) {
        pinnedRecords = snapshots.map {
            PinnedTabRecord(id: $0.id, declaration: $0.declaration, originProjectID: $0.originProjectID)
        }
        pendingPinnedLiveRestores = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snap in snap.live.map { (snap.id, $0) } }
        )
        pendingPinnedActiveTabID = activeTabID
        if !pinnedRecords.isEmpty { ensurePinnedWorkspace() }
    }

    /// Session names the not-yet-materialized pinned snapshots claim, for the
    /// launch orphan reaper's `known` set.
    func pendingPinnedSessionNames() -> Set<String> {
        Set(pendingPinnedLiveRestores.values.flatMap { paneSnapshots(of: $0.splitRoot).compactMap(\.sessionName) })
    }

    /// Materialize EVERY pinned record into a running tab at launch — pinned
    /// tabs are eager by design (they exist to keep things running), unlike
    /// projects, which stay lazy until selected. A record whose sessions
    /// survived reattaches its live snapshot; one whose sessions died — and
    /// one that was already unloaded at quit, or hand-added to `pinned.yaml`
    /// — rebuilds from its declaration, re-running its `run:` commands. A tab
    /// with any REMOTE pane always reattaches — its sessions live on the
    /// remote host, which a local `zmx ls` can't see (and which survive this
    /// machine's reboots by design). A failed listing (nil) also reattaches
    /// everything: fail toward reattach, never toward respawning over
    /// sessions that may be alive.
    ///
    /// The unloaded (dimmed) state therefore only arises mid-session, when a
    /// tab's own sessions die — and stays lazy there on purpose: eagerly
    /// respawning at the moment of death would be a crash loop for a `run:`
    /// that exits immediately.
    func materializeRestoredPinnedTabs(projects: [Project] = []) async {
        guard !pinnedRecords.isEmpty else { return }
        var aliveNames: Set<String>?
        if pendingPinnedLiveRestores.isEmpty {
            aliveNames = []
        } else if zmx.isBundled() {
            if let entries = await zmx.listSessionsWithClients() {
                aliveNames = Set(entries.map(\.name))
            }
        } else {
            // No persistence layer: nothing survived the quit.
            aliveNames = []
        }
        for record in pinnedRecords {
            guard !isPinnedTabLoaded(record.id) else { continue }
            if let snapshot = pendingPinnedLiveRestores.removeValue(forKey: record.id) {
                let panes = paneSnapshots(of: snapshot.splitRoot)
                let hasRemote = panes.contains { ProjectPath.isRemote($0.projectPath) }
                // ANY surviving pane reattaches the whole tab — deliberately:
                // rebuilding from the declaration would orphan the survivors,
                // and the fail-toward-reattach rule outranks re-running the
                // dead siblings' commands (those panes come back as fresh
                // shells in their cwds via the zmx upsert).
                let survived: Bool = if hasRemote {
                    true
                } else if let aliveNames {
                    panes.contains { pane in pane.sessionName.map { aliveNames.contains($0) } ?? false }
                } else {
                    true
                }
                if survived {
                    let tab = WorkspaceSerializer.restoreTab(snapshot, projectID: PinnedTabs.projectID)
                    insertPinnedTabAligned(tab, activate: false)
                    stampPinnedRemoteZmxPath(tab, record: record, projects: projects)
                    continue
                }
                logger.info("pinned tab \(record.id, privacy: .public): sessions died; respawning from layout")
            }
            ensurePinnedWorkspace()
            guard let tab = buildDeclaredPinnedTab(record) else { continue }
            insertPinnedTabAligned(tab, activate: false)
            stampPinnedRemoteZmxPath(tab, record: record, projects: projects)
        }
        if let ws = pinnedWorkspace, ws.activeTabID == nil {
            // Restore the selection the user quit with (persisted alongside
            // the pinned section), falling back to the first row.
            if let restored = pendingPinnedActiveTabID, ws.tabs.contains(where: { $0.id == restored }) {
                ws.activeTabID = restored
            } else {
                ws.activeTabID = ws.tabs.first?.id
            }
        }
        pendingPinnedActiveTabID = nil
        warmPinnedTabs()
        saveWorkspaces()
    }

    /// `remoteZmxPath` is a host property re-derived on every open — but the
    /// pinned workspace has no project to derive it from, so a pinned remote
    /// pane inherits it from the ORIGIN project the tab was pinned from.
    /// Without this, a relaunch rebuilds the pane with a nil zmx path and the
    /// remote attach/probe breaks on hosts that need the explicit path.
    private func stampPinnedRemoteZmxPath(_ tab: TerminalTab, record: PinnedTabRecord, projects: [Project]) {
        guard let origin = projects.first(where: { $0.id == record.originProjectID }),
              origin.zmxPath != nil
        else { return }
        for pane in tab.splitRoot.allPanes() where pane.isRemote {
            pane.remoteZmxPath = origin.zmxPath
        }
    }

    /// Start every pinned pane's shell off-screen via the shared stagger
    /// (`warmStaggered`). `warmPane` (the incubator) is idempotent, so a pane
    /// SwiftUI has already spawned — the active pinned tab of an active
    /// pinned workspace — just no-ops. After each warm the pane's
    /// process-exit callback is wired: the incubator wires no `onProcessExit`
    /// (background PROJECT tabs never needed one), but a background pinned
    /// tab must unload when its shell dies, or the row keeps posing as
    /// running with a dead surface behind it. `TerminalPane` re-wires the
    /// same destination when the tab is rendered, so the two never fight.
    private func warmPinnedTabs() {
        guard let ws = pinnedWorkspace else { return }
        warmStaggered(ws.tabs.flatMap { $0.splitRoot.allPanes() }) { [weak self] pane in
            guard let self else { return }
            pane.nsView?.onProcessExit = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.paneProcessExited(pane.id, projectID: PinnedTabs.projectID)
            }
        }
    }

    // MARK: - pinned.yaml

    /// Launch reconcile: the file is authoritative for MEMBERSHIP.
    /// - entries matched by id keep their record, adopting the file's
    ///   declaration (hand-edits take effect at the next restore);
    /// - unmatched entries become new UNLOADED records (a hand-added tab —
    ///   it spawns when selected, or shows as a dimmed row until then);
    /// - records missing from the file are unpinned: an unloaded one is
    ///   forgotten, one with a restorable live tab moves to its origin
    ///   project (a move — its surviving sessions reattach there).
    /// An absent or unparseable file is "no external input", never
    /// "remove everything" (editor truncate-then-write saves, mid-edit
    /// typos); unparseable additionally suspends auto-writes.
    func reconcilePinnedLayoutAtLaunch(projects: [Project]) {
        switch pinnedLayoutStore.read() {
        case .absent:
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            if !pinnedRecords.isEmpty { writePinnedLayout() }
        case let .invalid(reason):
            suspendPinnedLayoutWrites(reason: reason)
            pinnedMembershipStamp = pinnedRecords.map(\.id)
        case let .file(tabs, text):
            applyPinnedFileMembership(tabs, projects: projects)
            pinnedLayoutLastWrittenText = text
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            pinnedLayoutSuspended = false
        }
    }

    private func applyPinnedFileMembership(_ fileTabs: [LayoutTab], projects: [Project]) {
        // Entries carry no wire-level id (hostile to hand-editing); they are
        // matched back to records by name → exact layout → position
        // (`PinnedLayoutMatcher`). A matched record keeps its internal
        // identity — and thus its live-session snapshot — while adopting the
        // entry's declaration; an unmatched entry is a genuine addition.
        let matching = PinnedLayoutMatcher.match(entries: fileTabs, records: pinnedRecords)
        let result: [PinnedTabRecord] = matching.pairs.map { entry, record in
            if var record {
                record.declaration = entry
                return record
            }
            return PinnedTabRecord(id: UUID(), declaration: entry, originProjectID: nil)
        }
        let removed = matching.removed
        pinnedRecords = result
        for record in removed {
            guard let snapshot = pendingPinnedLiveRestores.removeValue(forKey: record.id) else {
                logger.info("pinned.yaml removed unloaded record \(record.id, privacy: .public); forgotten")
                continue
            }
            // The file unpinned a tab whose sessions may still be running:
            // honor it as a MOVE into the origin project, keeping the shells.
            let dest = projects.first { $0.id == record.originProjectID } ?? projects.first
            guard let dest else {
                logger.warning("pinned.yaml removed \(record.id, privacy: .public) but no project exists; forgotten")
                continue
            }
            logger.info("pinned.yaml unpinned \(record.id, privacy: .public) → \(dest.name, privacy: .public)")
            ensureAdoptableWorkspace(projectID: dest.id)
            let tab = WorkspaceSerializer.restoreTab(snapshot, projectID: dest.id)
            workspaces[dest.id]?.adoptTab(tab)
        }
    }

    /// Like `ensureWorkspace`, minus the default initial tab — an unpinned
    /// tab lands in a project the user may not have opened; giving it an
    /// extra empty tab on the side would be noise.
    func ensureAdoptableWorkspace(projectID: UUID) {
        if workspaces[projectID] == nil {
            workspaces[projectID] = Workspace(projectID: projectID, tabs: [], activeTabID: nil)
        }
    }

    /// Give every live pinned-workspace tab a record (a tab created inside
    /// the workspace — CLI `tab new`, a separated pane, a merge — is pinned
    /// from birth), then rewrite `pinned.yaml` iff membership changed.
    /// Called from every `saveWorkspaces()`, so it must stay cheap on the
    /// steady path: a set compare when nothing moved.
    func syncPinnedRecordsWithWorkspace() {
        if let ws = pinnedWorkspace {
            let known = Set(pinnedRecords.map(\.id))
            for tab in ws.tabs where !known.contains(tab.id) {
                let declaration = LayoutSerializer.pinnedDeclaration(for: tab)
                let record = PinnedTabRecord(id: tab.id, declaration: declaration, originProjectID: nil)
                pinnedRecords.insert(record, at: recordIndex(forLiveTab: tab.id, in: ws))
            }
        }
        let membership = pinnedRecords.map(\.id)
        if let stamp = pinnedMembershipStamp {
            if membership != stamp { writePinnedLayout() }
        } else if !membership.isEmpty {
            // No baseline yet (first pin of a fresh run, or a test that never
            // restored). An empty set with no baseline writes nothing — that
            // is what keeps a pre-restore save from clobbering the file.
            writePinnedLayout()
        }
    }

    /// Quit hook: refresh every LOADED record's declaration from its live tab
    /// (the moment the recipe is about to matter), persist the snapshot, and
    /// rewrite the file.
    func persistForTermination() {
        refreshPinnedDeclarationsFromLiveTabs()
        saveWorkspaces()
        // Nothing pinned and no file ever written this run → don't create
        // (or churn) pinned.yaml for users who never touch the feature. The
        // membership stamp can't stand in for this check — the launch
        // reconcile sets it on every branch, empty set included.
        if !(pinnedRecords.isEmpty && pinnedLayoutLastWrittenText == nil) {
            writePinnedLayout()
        }
    }

    /// Poll hook: when any pinned pane's foreground name changed since the
    /// last tick (a command started, ended, or was replaced), schedule a
    /// debounced declaration refresh + persist. Debounced because a command
    /// boundary often lands as two quick transitions (resolver race reports
    /// nil, then the real argv), and because each persist rewrites
    /// `pinned.yaml` — a file people dotfile-sync. Returns whether a persist
    /// was scheduled (for tests).
    @discardableResult
    func notePinnedForegroundChangesIfNeeded() -> Bool {
        guard let ws = pinnedWorkspace, !ws.tabs.isEmpty else {
            pinnedForegroundStamp = [:]
            return false
        }
        var stamp: [UUID: String?] = [:]
        for pane in ws.tabs.flatMap({ $0.splitRoot.allPanes() }) {
            stamp[pane.id] = pane.foregroundSample?.name
        }
        guard stamp != pinnedForegroundStamp else { return false }
        pinnedForegroundStamp = stamp
        schedulePinnedDeclarationPersist()
        return true
    }

    private func schedulePinnedDeclarationPersist() {
        pinnedDeclarationPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinnedDeclarationPersistWork = nil
                self.persistRefreshedPinnedDeclarations()
            }
        }
        pinnedDeclarationPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Re-capture every loaded record's declaration from its live tab and
    /// persist both layers (snapshot + `pinned.yaml`). The debounced landing
    /// point of `notePinnedForegroundChangesIfNeeded`; also safe to call
    /// directly.
    func persistRefreshedPinnedDeclarations() {
        guard !pinnedRecords.isEmpty, pinnedWorkspace?.tabs.isEmpty == false else { return }
        let before = pinnedRecords.map(\.declaration)
        refreshPinnedDeclarationsFromLiveTabs()
        // A boundary that changed nothing observable (the run-preserving
        // merge often absorbs it) must not churn two files.
        guard pinnedRecords.map(\.declaration) != before else { return }
        saveWorkspaces()
        writePinnedLayout()
    }

    func refreshPinnedDeclarationsFromLiveTabs() {
        guard let ws = pinnedWorkspace else { return }
        for index in pinnedRecords.indices {
            guard let live = ws.tabs.first(where: { $0.id == pinnedRecords[index].id }) else { continue }
            var fresh = LayoutSerializer.pinnedDeclaration(for: live)
            // Never let an idle capture ERASE the respawn recipe — see
            // `LayoutNode.preservingRuns(from:)` for the moments this guards.
            fresh.layout = fresh.layout.preservingRuns(from: pinnedRecords[index].declaration.layout)
            pinnedRecords[index].declaration = fresh
        }
    }

    /// Rewrite `pinned.yaml` from the records — after absorbing any external
    /// edit made since our last write (tracked by exact text). Additions
    /// absorb as new unloaded records and edits update declarations;
    /// removals of LIVE tabs are honored at launch only (this path has no
    /// project list to move them into) and get re-declared. A file that no
    /// longer parses suspends auto-writes instead of clobbering the user's
    /// mid-edit work.
    func writePinnedLayout() {
        // ONE read serves both the suspension re-check and the absorb — the
        // read parses the whole file, so doubling it doubled the cost.
        let onDisk = pinnedLayoutStore.read()
        if pinnedLayoutSuspended {
            // Re-check: the user may have fixed (or deleted) the file since.
            switch onDisk {
            case .absent,
                 .file:
                pinnedLayoutSuspended = false
            case .invalid:
                return
            }
        }
        switch onDisk {
        case .absent:
            break
        case let .invalid(reason):
            suspendPinnedLayoutWrites(reason: reason)
            return
        case let .file(tabs, text):
            if text != pinnedLayoutLastWrittenText {
                absorbExternalPinnedEdits(tabs)
            }
        }
        do {
            pinnedLayoutLastWrittenText = try pinnedLayoutStore.write(tabs: pinnedRecords.map(\.declaration))
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            // No noteLayoutFilesChanged(): the Projects settings pane's
            // listing filters pinned.yaml out, so a rescan can never observe
            // this write — bumping the version would only force a re-parse of
            // every project file for zero visible delta.
        } catch {
            logger.error("Failed to write pinned.yaml: \(error, privacy: .public)")
        }
    }

    /// Write-time absorption (the app is running; launch reconcile handles
    /// the rest): the records adopt the file's ORDER and declarations,
    /// additions become unloaded records, and removals of UNLOADED records
    /// are honored. Removals of LIVE tabs can't be honored here (no project
    /// list to move them into) — those records are kept, appended after the
    /// file's order, and get re-declared by the write that follows.
    private func absorbExternalPinnedEdits(_ fileTabs: [LayoutTab]) {
        logger.info("pinned.yaml changed externally; absorbing before write")
        let matching = PinnedLayoutMatcher.match(entries: fileTabs, records: pinnedRecords)
        var result: [PinnedTabRecord] = matching.pairs.map { entry, record in
            if var record {
                record.declaration = entry
                return record
            }
            return PinnedTabRecord(id: UUID(), declaration: entry, originProjectID: nil)
        }
        result += matching.removed.filter {
            isPinnedTabLoaded($0.id) || pendingPinnedLiveRestores[$0.id] != nil
        }
        pinnedRecords = result
        alignPinnedWorkspaceOrder()
    }

    private func suspendPinnedLayoutWrites(reason: String) {
        guard !pinnedLayoutSuspended else { return }
        pinnedLayoutSuspended = true
        logger.error("pinned.yaml auto-save suspended: \(reason, privacy: .public)")
        pendingLayoutError = LayoutError(
            verb: "save",
            message: "\(reason)\n\nPinned-tab auto-save is paused so your edits aren’t overwritten. "
                + "Fix the file (or delete it) to resume.",
            customTitle: "Pinned layout file problem"
        )
    }

    // MARK: - Record/live index alignment

    /// The pinned workspace holds only LOADED tabs; the sidebar shows every
    /// record. These helpers keep the two orders consistent.
    private func liveIndex(forRecordIndex recordIndex: Int) -> Int {
        guard let ws = pinnedWorkspace else { return 0 }
        let liveIDs = Set(ws.tabs.map(\.id))
        return pinnedRecords.prefix(recordIndex).count { liveIDs.contains($0.id) }
    }

    private func recordIndex(forLiveTab tabID: UUID, in ws: Workspace) -> Int {
        // Insert after the record of the nearest preceding live tab.
        guard let liveIndex = ws.tabs.firstIndex(where: { $0.id == tabID }) else { return pinnedRecords.count }
        for earlier in ws.tabs[..<liveIndex].reversed() {
            if let idx = pinnedRecords.firstIndex(where: { $0.id == earlier.id }) {
                return idx + 1
            }
        }
        return 0
    }

    /// Insert a (re)loaded tab into the workspace at the slot matching its
    /// record's position among the loaded records.
    private func insertPinnedTabAligned(_ tab: TerminalTab, activate: Bool = true) {
        guard let ws = pinnedWorkspace,
              let recordIndex = pinnedRecords.firstIndex(where: { $0.id == tab.id })
        else { return }
        if activate {
            ws.adoptTab(tab, at: liveIndex(forRecordIndex: recordIndex))
        } else {
            ws.tabs.insert(tab, at: min(liveIndex(forRecordIndex: recordIndex), ws.tabs.count))
        }
    }

    /// Re-sort the loaded tabs to the records' order (after a sidebar
    /// reorder).
    private func alignPinnedWorkspaceOrder() {
        guard let ws = pinnedWorkspace else { return }
        let order = Dictionary(uniqueKeysWithValues: pinnedRecords.enumerated().map { ($0.element.id, $0.offset) })
        ws.tabs.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private func paneSnapshots(of node: SplitNodeSnapshot) -> [PaneSnapshot] {
        switch node {
        case let .pane(p): [p]
        case let .split(b): paneSnapshots(of: b.first) + paneSnapshots(of: b.second)
        }
    }
}
