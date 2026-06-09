import Foundation
@testable import Macterm
import Testing

@MainActor
struct LayoutReconcilerTests {
    /// Build a single-tab workspace from a split tree.
    private func workspace(projectID: UUID, root: SplitNode, title: String? = nil) -> Workspace {
        let tab = TerminalTab(id: UUID(), splitRoot: root, focusedPaneID: root.allPanes().first?.id, customTitle: title)
        return Workspace(projectID: projectID, tabs: [tab], activeTabID: tab.id)
    }

    /// Parse a layout from YAML, failing the test loudly on a parse error.
    private func layout(_ yaml: String) -> LayoutFile {
        try! LayoutFile.parse(yaml: yaml)
    }

    /// Run the reconciler with a stubbed live-command lookup. Unit tests have no
    /// live surface, so by default we model each pane's *live* command as the
    /// one it was constructed with (`Pane.command`) — i.e. "the pane is
    /// currently running what it was spawned with." Tests exercising idle /
    /// exited processes pass their own `liveCommand`. `liveShellName` models the
    /// basename of the shell an idle pane is running (default: the pane's
    /// declared `shell`, else nil); tests swapping shells inject their own.
    private func plan(
        _ file: LayoutFile,
        workspace: Workspace?,
        projectRoot: String,
        projectID: UUID,
        liveCommand: @escaping (Pane) -> String? = { $0.command },
        liveShellName: @escaping (Pane) -> String? = { $0.shell.map { ($0 as NSString).lastPathComponent } }
    ) -> LayoutReconciler.Plan {
        LayoutReconciler.plan(
            layout: file,
            workspace: workspace,
            projectRoot: projectRoot,
            projectID: projectID,
            liveCommand: liveCommand,
            liveShellName: liveShellName
        )
    }

    @Test
    func identical_layout_keeps_all_panes_and_destroys_nothing() {
        let pid = UUID()
        let dev = Pane(projectPath: "/proj/api", projectID: pid, command: "npm run dev")
        let shell = Pane(projectPath: "/proj", projectID: pid)
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .horizontal, ratio: 0.6,
            first: .pane(dev), second: .pane(shell)
        )))

        let file = layout("""
        tabs:
          - split:
              direction: horizontal
              ratio: 0.6
              first:  { cwd: "./api", run: "npm run dev" }
              second: {}
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.isEmpty)
        #expect(!plan.isDestructive)
        // Both live panes reused (same IDs in the new tree).
        let newIDs = Set(plan.tabs[0].root.allPanes().map(\.id))
        #expect(newIDs == Set([dev.id, shell.id]))
    }

    @Test
    func only_ratio_differs_reuses_panes_without_destruction() {
        let pid = UUID()
        let dev = Pane(projectPath: "/proj", projectID: pid, command: "npm run dev")
        let shell = Pane(projectPath: "/proj", projectID: pid)
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .horizontal, ratio: 0.5,
            first: .pane(dev), second: .pane(shell)
        )))

        let file = layout("""
        tabs:
          - split:
              direction: horizontal
              ratio: 0.8
              first:  { run: "npm run dev" }
              second: {}
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.isEmpty)
        // New ratio applied, panes preserved.
        guard case let .split(b) = plan.tabs[0].root else { Issue.record("expected split")
            return
        }
        #expect(b.ratio == 0.8)
        #expect(Set(plan.tabs[0].root.allPanes().map(\.id)) == Set([dev.id, shell.id]))
    }

    @Test
    func changed_run_respawns_only_that_pane() {
        let pid = UUID()
        let dev = Pane(projectPath: "/proj", projectID: pid, command: "npm run dev")
        let test = Pane(projectPath: "/proj", projectID: pid, command: "npm test")
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .vertical, ratio: 0.5,
            first: .pane(dev), second: .pane(test)
        )))

        // dev unchanged, test's command changed.
        let file = layout("""
        tabs:
          - split:
              direction: vertical
              first:  { run: "npm run dev" }
              second: { run: "npm start" }
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        // Exactly the changed pane is destroyed.
        #expect(plan.panesToDestroy.map(\.id) == [test.id])
        #expect(plan.isDestructive)
        let newIDs = Set(plan.tabs[0].root.allPanes().map(\.id))
        #expect(newIDs.contains(dev.id)) // kept
        #expect(!newIDs.contains(test.id)) // replaced
    }

    @Test
    func moved_pane_with_same_identity_survives_structural_edit() {
        let pid = UUID()
        let dev = Pane(projectPath: "/proj/api", projectID: pid, command: "npm run dev")
        let shell = Pane(projectPath: "/proj", projectID: pid)
        // Live: dev is `first`. Declared: dev is `second` (and direction flipped).
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .horizontal, ratio: 0.5,
            first: .pane(dev), second: .pane(shell)
        )))

        let file = layout("""
        tabs:
          - split:
              direction: vertical
              first:  {}
              second: { cwd: "./api", run: "npm run dev" }
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.isEmpty)
        // dev kept despite moving position; identity matched on (run, cwd).
        #expect(Set(plan.tabs[0].root.allPanes().map(\.id)).contains(dev.id))
    }

    @Test
    func extra_live_pane_is_flagged_for_destruction() {
        let pid = UUID()
        let dev = Pane(projectPath: "/proj", projectID: pid, command: "npm run dev")
        let extra = Pane(projectPath: "/proj", projectID: pid, command: "htop")
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .horizontal, ratio: 0.5,
            first: .pane(dev), second: .pane(extra)
        )))

        // Layout only declares dev.
        let file = layout("""
        tabs:
          - { run: "npm run dev" }
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.map(\.id) == [extra.id])
        #expect(plan.isDestructive)
    }

    @Test
    func plain_shells_match_positionally() {
        let pid = UUID()
        let s1 = Pane(projectPath: "/proj", projectID: pid)
        let s2 = Pane(projectPath: "/proj", projectID: pid)
        let ws = workspace(projectID: pid, root: .split(SplitBranch(
            direction: .horizontal, ratio: 0.5,
            first: .pane(s1), second: .pane(s2)
        )))

        // Two declared plain shells → reuse the two live shells positionally.
        let file = layout("""
        tabs:
          - split:
              direction: horizontal
              first:  {}
              second: {}
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.isEmpty)
        #expect(Set(plan.tabs[0].root.allPanes().map(\.id)) == Set([s1.id, s2.id]))
    }

    @Test
    func declared_shell_mismatch_respawns_the_pane() {
        // A pane idle in `nu` against a declared `shell: /bin/zsh` is out of sync
        // — it must be destroyed and respawned, not reused.
        let pid = UUID()
        let live = Pane(projectPath: "/proj", projectID: pid)
        let ws = workspace(projectID: pid, root: .pane(live))

        let file = layout("""
        tabs:
          - shell: /bin/zsh
        """)

        let plan = plan(
            file,
            workspace: ws,
            projectRoot: "/proj",
            projectID: pid,
            liveCommand: { _ in nil }, // idle at a prompt
            liveShellName: { _ in "nu" } // …but running nu, not zsh
        )
        #expect(plan.panesToDestroy.map(\.id) == [live.id])
        #expect(plan.isDestructive)
        #expect(!plan.tabs[0].root.allPanes().map(\.id).contains(live.id))
    }

    @Test
    func declared_shell_match_reuses_the_pane() {
        // A pane idle in the declared shell is reused, not respawned.
        let pid = UUID()
        let live = Pane(projectPath: "/proj", projectID: pid)
        let ws = workspace(projectID: pid, root: .pane(live))

        let file = layout("""
        tabs:
          - shell: /bin/zsh
        """)

        let plan = plan(
            file,
            workspace: ws,
            projectRoot: "/proj",
            projectID: pid,
            liveCommand: { _ in nil },
            liveShellName: { _ in "zsh" }
        )
        #expect(plan.panesToDestroy.isEmpty)
        #expect(plan.tabs[0].root.allPanes().map(\.id) == [live.id])
    }

    @Test
    func no_live_workspace_spawns_everything_non_destructively() {
        let pid = UUID()
        let file = layout("""
        tabs:
          - split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """)

        let plan = plan(file, workspace: nil, projectRoot: "/proj", projectID: pid)
        #expect(plan.panesToDestroy.isEmpty)
        #expect(!plan.isDestructive)
        #expect(plan.tabs[0].root.allPanes().count == 2)
    }

    @Test
    func unmatched_live_tab_is_closed() {
        let pid = UUID()
        let keep = Pane(projectPath: "/proj", projectID: pid, command: "npm run dev")
        let goneShell = Pane(projectPath: "/proj", projectID: pid)
        let tabA = TerminalTab(id: UUID(), splitRoot: .pane(keep), focusedPaneID: keep.id, customTitle: "Dev")
        let tabB = TerminalTab(id: UUID(), splitRoot: .pane(goneShell), focusedPaneID: goneShell.id, customTitle: "Scratch")
        let ws = Workspace(projectID: pid, tabs: [tabA, tabB], activeTabID: tabA.id)

        // Only the "Dev" tab is declared.
        let file = layout("""
        tabs:
          - name: "Dev"
            run: "npm run dev"
        """)

        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid)
        #expect(plan.tabsToClose == [tabB.id])
        #expect(plan.panesToDestroy.map(\.id) == [goneShell.id])
        // Dev tab's pane kept.
        #expect(plan.tabs.count == 1)
        #expect(plan.tabs[0].existingTabID == tabA.id)
        #expect(Set(plan.tabs[0].root.allPanes().map(\.id)) == Set([keep.id]))
    }

    @Test
    func pane_idle_despite_declared_run_is_not_in_sync() {
        // The reported bug: a pane spawned with `btop` that the user has since
        // quit is idle. Identity is the *live* command, so an idle pane (live
        // command nil) does NOT match a declared `run: btop` — it's destroyed
        // and a fresh pane is spawned to run btop again.
        let pid = UUID()
        let stale = Pane(projectPath: "/proj", projectID: pid, command: "btop")
        let ws = workspace(projectID: pid, root: .pane(stale))

        let file = layout("""
        tabs:
          - { run: "btop" }
        """)

        // Live command is nil (idle) even though it was spawned with btop.
        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid) { _ in nil }
        #expect(plan.panesToDestroy.map(\.id) == [stale.id])
        #expect(plan.isDestructive)
        // A fresh pane (new id) is planned to run btop.
        let newPanes = plan.tabs[0].root.allPanes()
        #expect(newPanes.count == 1)
        #expect(newPanes[0].id != stale.id)
        #expect(newPanes[0].command == "btop")
    }

    @Test
    func pane_running_declared_command_stays_in_sync() {
        // Counterpart: a pane actually running its declared command matches and
        // is kept untouched.
        let pid = UUID()
        let live = Pane(projectPath: "/proj", projectID: pid, command: "btop")
        let ws = workspace(projectID: pid, root: .pane(live))

        let file = layout("""
        tabs:
          - { run: "btop" }
        """)

        // Live command equals the declared run.
        let plan = plan(file, workspace: ws, projectRoot: "/proj", projectID: pid) { _ in "btop" }
        #expect(plan.panesToDestroy.isEmpty)
        #expect(!plan.isDestructive)
        #expect(plan.tabs[0].root.allPanes().map(\.id) == [live.id])
    }
}
