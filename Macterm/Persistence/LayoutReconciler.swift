import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LayoutReconciler")

/// Reconciles a live workspace toward a declared `LayoutFile` with *minimal
/// destruction*: panes that already match the declaration are kept — their
/// surfaces re-parented into the declared tree shape rather than torn down — so
/// changing only a ratio resizes in place, and a moved-but-unchanged pane
/// survives a structural edit. A command leaf matches by live command + cwd; a
/// plain-shell leaf matches an idle pane (positionally), but a leaf declaring a
/// specific `shell:` only matches an idle pane running that shell — so swapping
/// a pane's `shell:` respawns it. Only panes that genuinely deviate (a
/// different/no command, a different shell, or live panes the file no longer
/// mentions) are destroyed.
///
/// The plan is computed as a pure function (`plan(...)`) so the matching logic
/// is unit-testable without touching real surfaces; `AppState` executes the
/// resulting plan, destroying surfaces and swapping in the new trees.
@MainActor
enum LayoutReconciler {
    /// A live pane's identity for matching: its *current* foreground command
    /// (what's actually running now, via `liveCommand`) plus its cwd — NOT the
    /// command it was spawned with, so a pane that has since exited its command
    /// no longer matches a declaration that expects it. `command == nil` (a pane
    /// idle at a prompt) has no command identity and is matched positionally.
    struct Identity: Hashable {
        let command: String?
        let cwd: String
    }

    /// The reconciled result for one tab.
    struct PlannedTab {
        /// Existing tab to reuse (preserving its id), if the declared tab
        /// matched a live one; nil for a brand-new tab.
        let existingTabID: UUID?
        let title: String?
        let root: SplitNode
        let focusedPaneID: UUID?
    }

    struct Plan {
        let tabs: [PlannedTab]
        /// Live panes that will be destroyed: those not matched by any
        /// declaration (running a different command than declared, idle where a
        /// command is declared, or in a tab the file no longer mentions). Empty
        /// → a fully non-destructive apply.
        let panesToDestroy: [Pane]
        /// Live tab ids that no longer appear in the layout and will be closed.
        let tabsToClose: [UUID]

        var isDestructive: Bool { !panesToDestroy.isEmpty || !tabsToClose.isEmpty }
    }

    /// Compute a reconcile plan from a declared layout against a live workspace.
    /// Reuses live `Pane` objects for matched leaves (so their surfaces survive)
    /// and constructs new `Pane`s (via `LayoutBuilder`) for spawns/respawns.
    /// `liveCommand` returns a pane's current foreground command (what's
    /// actually running), used as its match identity. Defaults to
    /// `ProcessInspector.runningCommand`; tests inject a stub since unit tests
    /// have no live surface to inspect.
    static func plan(
        layout file: LayoutFile,
        workspace: Workspace?,
        projectRoot: String,
        projectID: UUID,
        liveCommand: @escaping (Pane) -> String? = { ProcessInspector.runningCommand(forPane: $0) },
        liveShellName: @escaping (Pane) -> String? = { ProcessInspector.runningProcessName(forPane: $0) }
    ) -> Plan {
        let liveTabs = workspace?.tabs ?? []
        var consumedTabIDs = Set<UUID>()
        var reusedPaneIDs = Set<UUID>()
        var plannedTabs: [PlannedTab] = []

        for declaredTab in file.tabs {
            // Match a declared tab to a live tab by name, else by position
            // among not-yet-consumed live tabs.
            let liveTab = matchTab(declaredTab, in: liveTabs, consumed: consumedTabIDs)
            if let liveTab { consumedTabIDs.insert(liveTab.id) }

            // Pool of live panes available to reuse for this tab, indexed by
            // identity. Order within an identity bucket is the tab's pane order
            // (stable, depth-first) so duplicate (run,cwd) pairs pair stably.
            var pool = PanePool(
                panes: liveTab?.splitRoot.allPanes() ?? [],
                liveCommand: liveCommand,
                liveShellName: liveShellName
            )

            let ctx = BuildContext(projectRoot: projectRoot, projectID: projectID)
            let root = buildTree(declaredTab.layout, ctx: ctx, pool: &pool, reused: &reusedPaneIDs)
            plannedTabs.append(PlannedTab(
                existingTabID: liveTab?.id,
                title: declaredTab.name,
                root: root,
                focusedPaneID: root.allPanes().first?.id
            ))
        }

        // Anything live that wasn't reused is destroyed; live tabs not matched
        // to any declared tab are closed (their panes destroyed too).
        var panesToDestroy: [Pane] = []
        var tabsToClose: [UUID] = []
        for tab in liveTabs {
            if consumedTabIDs.contains(tab.id) {
                for pane in tab.splitRoot.allPanes() where !reusedPaneIDs.contains(pane.id) {
                    panesToDestroy.append(pane)
                }
            } else {
                tabsToClose.append(tab.id)
                panesToDestroy.append(contentsOf: tab.splitRoot.allPanes())
            }
        }

        let plan = Plan(tabs: plannedTabs, panesToDestroy: panesToDestroy, tabsToClose: tabsToClose)
        let summary = "tabs=\(plannedTabs.count) destroy=\(panesToDestroy.count) close=\(tabsToClose.count)"
        logger.info("plan: \(summary, privacy: .public) destructive=\(plan.isDestructive, privacy: .public)")
        return plan
    }

    // MARK: - Tab matching

    private static func matchTab(
        _ declared: LayoutTab,
        in liveTabs: [TerminalTab],
        consumed: Set<UUID>
    ) -> TerminalTab? {
        let available = liveTabs.filter { !consumed.contains($0.id) }
        // Prefer a name match (against the live tab's custom title).
        if let name = declared.name,
           let byName = available.first(where: { $0.customTitle == name })
        {
            return byName
        }
        // Otherwise pair by position: the Nth declared tab to the Nth still-
        // available live tab.
        return available.first
    }

    // MARK: - Tree building with pane reuse

    /// A consumable pool of live panes, matched out by identity (command+cwd)
    /// with a positional fallback for panes that aren't currently running a
    /// command. Identity uses the pane's *live* foreground command (what's
    /// actually running now), NOT the command it was spawned with — so a pane
    /// declared to run `btop` but sitting idle won't match a declared `run:
    /// btop` (it'll be respawned). The live command is compared verbatim to the
    /// declared `run` (no path normalization).
    @MainActor
    private struct PanePool {
        private var byIdentity: [Identity: [Pane]]
        /// Panes with no live command (idle at a prompt), in tree order, paired
        /// with the basename of the shell each is actually running. Used for
        /// positional reuse by declared plain-shell leaves — but a leaf that
        /// declares a specific `shell:` only reuses an idle pane running *that*
        /// shell, so applying a layout that swaps a pane's shell respawns it.
        private var idlePanes: [(pane: Pane, shell: String?)]

        init(panes: [Pane], liveCommand: (Pane) -> String?, liveShellName: (Pane) -> String?) {
            var buckets: [Identity: [Pane]] = [:]
            var idle: [(Pane, String?)] = []
            for pane in panes {
                if let live = liveCommand(pane) {
                    buckets[Identity(command: live, cwd: pane.projectPath), default: []].append(pane)
                } else {
                    idle.append((pane, liveShellName(pane)))
                }
            }
            byIdentity = buckets
            idlePanes = idle
        }

        /// Take the next live pane matching this declared leaf, if any.
        /// A declared command matches only a pane running that exact command.
        /// A declared plain shell (`command == nil`) consumes an idle pane: if
        /// `shell` is declared, only an idle pane running that shell (compared
        /// by basename); otherwise any idle pane (positional).
        mutating func take(command: String?, cwd: String, shell: String?) -> Pane? {
            if command == nil {
                let wanted = shell.map { ($0 as NSString).lastPathComponent }
                guard let index = idlePanes.firstIndex(where: { entry in
                    wanted == nil || entry.shell == wanted
                })
                else { return nil }
                return idlePanes.remove(at: index).pane
            }
            let id = Identity(command: command, cwd: cwd)
            guard var bucket = byIdentity[id], !bucket.isEmpty else { return nil }
            let pane = bucket.removeFirst()
            byIdentity[id] = bucket
            return pane
        }
    }

    /// Immutable per-build inputs, bundled to keep `buildTree`'s signature small.
    private struct BuildContext {
        let projectRoot: String
        let projectID: UUID
    }

    private static func buildTree(
        _ node: LayoutNode,
        ctx: BuildContext,
        pool: inout PanePool,
        reused: inout Set<UUID>
    ) -> SplitNode {
        switch node {
        case let .pane(p):
            let cwd = LayoutBuilder.resolveCwd(p.cwd, projectRoot: ctx.projectRoot)
            let command = (p.run?.isEmpty == false) ? p.run : nil
            let shell = (p.shell?.isEmpty == false) ? p.shell : nil
            if let existing = pool.take(command: command, cwd: cwd, shell: shell) {
                // Reuse the live pane: same identity, surface preserved.
                reused.insert(existing.id)
                return .pane(existing)
            }
            // No match → fresh pane (spawn / respawn).
            return .pane(LayoutBuilder.makePane(p, projectRoot: ctx.projectRoot, projectID: ctx.projectID))
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.resolvedRatio),
                first: buildTree(b.first, ctx: ctx, pool: &pool, reused: &reused),
                second: buildTree(b.second, ctx: ctx, pool: &pool, reused: &reused)
            ))
        }
    }
}
