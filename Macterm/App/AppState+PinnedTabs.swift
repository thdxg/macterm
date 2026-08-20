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
///   are never killed by pinning state changes.
/// - A pinned tab cannot be closed or unloaded by the user; it unloads only
///   when its own sessions die (`paneProcessExited`), keeping the record.
///   Selecting an unloaded record rebuilds the tab from its declaration,
///   re-running its `run:` commands.
/// - `pinned.yaml` (see `PinnedLayoutStore`) mirrors the records and is
///   authoritative for membership at launch. It is rewritten on membership
///   changes and refreshed from live state at quit; external edits are
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
        let declaration = LayoutSerializer.pinnedDeclaration(for: tab, id: tabID)
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
        let clamped = max(0, min(destination, pinnedRecords.count))
        var to = clamped > from ? clamped - 1 : clamped
        to = max(0, min(to, pinnedRecords.count - 1))
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
    /// declaration. Shared by restore-on-selection and the eager launch load.
    private func buildDeclaredPinnedTab(_ record: PinnedTabRecord) -> TerminalTab? {
        let layout = LayoutFile(name: nil, tabs: [record.declaration])
        let plan = LayoutReconciler.plan(
            layout: layout,
            workspace: nil,
            projectRoot: PinnedTabs.fallbackRoot,
            projectID: PinnedTabs.projectID
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
    func restorePinnedState(_ snapshots: [PinnedTabSnapshot]) {
        pinnedRecords = snapshots.map {
            PinnedTabRecord(id: $0.id, declaration: $0.declaration, originProjectID: $0.originProjectID)
        }
        pendingPinnedLiveRestores = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snap in snap.live.map { (snap.id, $0) } }
        )
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
    func materializeRestoredPinnedTabs() async {
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
                    continue
                }
                logger.info("pinned tab \(record.id, privacy: .public): sessions died; respawning from layout")
            }
            ensurePinnedWorkspace()
            guard let tab = buildDeclaredPinnedTab(record) else { continue }
            insertPinnedTabAligned(tab, activate: false)
        }
        if activeProjectID == PinnedTabs.projectID, let ws = pinnedWorkspace, ws.activeTabID == nil {
            ws.activeTabID = ws.tabs.first?.id
        }
        warmPinnedTabs()
        saveWorkspaces()
    }

    /// Start every pinned pane's shell off-screen, staggered like
    /// `warmFocusedProject` (each warm is a login shell / a `zmx attach`;
    /// firing them all in one tick multiplies launch pressure). `warmPane`
    /// (the incubator) is idempotent, so a pane SwiftUI has already spawned —
    /// the active pinned tab of an active pinned workspace — just no-ops.
    private func warmPinnedTabs() {
        guard let ws = pinnedWorkspace else { return }
        let panes = ws.tabs.flatMap { $0.splitRoot.allPanes() }
        for (index, pane) in panes.enumerated() {
            if index == 0 {
                warmPane(pane)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.125 * Double(index)) { [weak self, weak pane] in
                guard let self, let pane else { return }
                warmPane(pane)
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
        case let .file(file, text):
            applyPinnedFileMembership(file, projects: projects)
            pinnedLayoutLastWrittenText = text
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            pinnedLayoutSuspended = false
            // A hand-added entry just got an app-assigned id — canonicalize
            // the file NOW, or a later edit of that (still id-less) entry
            // would absorb as a brand-new addition instead of an update.
            if (file.tabs ?? []).contains(where: { $0.id == nil }) {
                writePinnedLayout()
            }
        }
    }

    private func applyPinnedFileMembership(_ file: PinnedLayoutFile, projects: [Project]) {
        let fileTabs = file.tabs ?? []
        let byID = Dictionary(uniqueKeysWithValues: pinnedRecords.map { ($0.id, $0) })
        var result: [PinnedTabRecord] = []
        var kept = Set<UUID>()
        for tab in fileTabs {
            if let id = tab.id, var existing = byID[id] {
                var declaration = tab
                declaration.id = id
                existing.declaration = declaration
                result.append(existing)
                kept.insert(id)
            } else {
                let id = tab.id ?? UUID()
                var declaration = tab
                declaration.id = id
                result.append(PinnedTabRecord(id: id, declaration: declaration, originProjectID: nil))
            }
        }
        let removed = pinnedRecords.filter { !kept.contains($0.id) }
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
            ensureWorkspaceForUnpin(projectID: dest.id, path: dest.path)
            let tab = WorkspaceSerializer.restoreTab(snapshot, projectID: dest.id)
            workspaces[dest.id]?.adoptTab(tab)
        }
    }

    /// Like `ensureWorkspace`, minus the default initial tab — an unpin-at-
    /// launch lands a tab in a project the user hasn't opened; giving it an
    /// extra empty tab on the side would be noise.
    private func ensureWorkspaceForUnpin(projectID: UUID, path _: String) {
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
                let declaration = LayoutSerializer.pinnedDeclaration(for: tab, id: tab.id)
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
        if !(pinnedRecords.isEmpty && pinnedLayoutLastWrittenText == nil && pinnedMembershipStamp == nil) {
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
        refreshPinnedDeclarationsFromLiveTabs()
        saveWorkspaces()
        writePinnedLayout()
    }

    func refreshPinnedDeclarationsFromLiveTabs() {
        guard let ws = pinnedWorkspace else { return }
        for index in pinnedRecords.indices {
            guard let live = ws.tabs.first(where: { $0.id == pinnedRecords[index].id }) else { continue }
            pinnedRecords[index].declaration = LayoutSerializer.pinnedDeclaration(
                for: live, id: pinnedRecords[index].id
            )
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
        if pinnedLayoutSuspended {
            // Re-check: the user may have fixed (or deleted) the file since.
            switch pinnedLayoutStore.read() {
            case .absent,
                 .file:
                pinnedLayoutSuspended = false
            case .invalid:
                return
            }
        }
        switch pinnedLayoutStore.read() {
        case .absent:
            break
        case let .invalid(reason):
            suspendPinnedLayoutWrites(reason: reason)
            return
        case let .file(file, text):
            if text != pinnedLayoutLastWrittenText {
                absorbExternalPinnedEdits(file)
            }
        }
        do {
            let tabs = pinnedRecords.map { record in
                var tab = record.declaration
                tab.id = record.id
                return tab
            }
            pinnedLayoutLastWrittenText = try pinnedLayoutStore.write(tabs: tabs)
            pinnedMembershipStamp = pinnedRecords.map(\.id)
            noteLayoutFilesChanged()
        } catch {
            logger.error("Failed to write pinned.yaml: \(error, privacy: .public)")
        }
    }

    /// Write-time absorption (the app is running; launch reconcile handles
    /// the rest): additions → unloaded records; matched entries → declaration
    /// updates; removals → only records that are UNLOADED are forgotten.
    private func absorbExternalPinnedEdits(_ file: PinnedLayoutFile) {
        logger.info("pinned.yaml changed externally; absorbing before write")
        let fileTabs = file.tabs ?? []
        // Every id the file accounts for — including the fresh ones assigned
        // to id-less hand-added entries, or the removal sweep below would
        // delete an addition the moment it was absorbed.
        var keptIDs = Set<UUID>()
        for tab in fileTabs {
            if let id = tab.id, let index = pinnedRecords.firstIndex(where: { $0.id == id }) {
                var declaration = tab
                declaration.id = id
                pinnedRecords[index].declaration = declaration
                keptIDs.insert(id)
            } else {
                let id = tab.id ?? UUID()
                var declaration = tab
                declaration.id = id
                pinnedRecords.append(PinnedTabRecord(id: id, declaration: declaration, originProjectID: nil))
                keptIDs.insert(id)
            }
        }
        pinnedRecords.removeAll { record in
            !keptIDs.contains(record.id) && !isPinnedTabLoaded(record.id)
                && pendingPinnedLiveRestores[record.id] == nil
        }
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
