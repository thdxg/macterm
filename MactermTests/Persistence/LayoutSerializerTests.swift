import Foundation
@testable import Macterm
import Testing

@MainActor
struct LayoutSerializerTests {
    @Test
    func emits_tab_topology_with_direction_and_ratio() {
        let ws = Workspace(projectID: UUID(), projectPath: "/proj")
        let (tree, _) = build(H(pane("a", projectPath: "/proj"), pane("b", projectPath: "/proj/sub"), ratio: 0.7))
        ws.tabs[0].splitRoot = tree

        let file = LayoutSerializer.layout(for: ws, projectName: "proj", projectRoot: "/proj")
        #expect(file.tabs.count == 1)
        guard case let .split(b) = file.tabs[0].layout else {
            Issue.record("expected split")
            return
        }
        #expect(b.direction == .horizontal)
        #expect(b.ratio == 0.7)
    }

    @Test
    func cwd_is_emitted_project_relative() {
        // Inside the root → relative; the root itself → nil; outside → absolute.
        #expect(LayoutSerializer.relativePath("/proj/api", to: "/proj") == "./api")
        #expect(LayoutSerializer.relativePath("/proj", to: "/proj") == nil)
        #expect(LayoutSerializer.relativePath("/elsewhere", to: "/proj") == "/elsewhere")
    }

    @Test
    func remote_cwd_round_trips_as_pure_strings() {
        // Remote specs (#104) never touch local filesystem semantics: the root
        // itself → nil, a spec extending the root → the bare relative suffix
        // (LayoutBuilder.resolveCwd joins it back to the identical spec), and
        // anything else passes through verbatim.
        let root = "devbox:~/dev/api"
        #expect(LayoutSerializer.relativePath(root, to: root) == nil)
        #expect(LayoutSerializer.relativePath("devbox:~/dev/api/sub", to: root) == "sub")
        #expect(LayoutBuilder.resolveCwd("sub", projectRoot: root) == "devbox:~/dev/api/sub")
        #expect(LayoutSerializer.relativePath("devbox:/srv/other", to: root) == "devbox:/srv/other")
    }

    @Test
    func records_remote_foreground_command_through_the_default_seam() {
        // Remote pane (#104): the default liveCommand seam answers from the
        // probe-cached remote foreground, so Save Layout captures a running
        // command with no local pid (the bug: it used to save an empty leaf).
        let root = "devbox:~/dev/api"
        let ws = Workspace(projectID: UUID(), projectPath: root)
        let pane = Pane(projectPath: root, projectID: ws.projectID)
        pane.applyRemoteForeground(RemoteForeground(comm: "btop", command: "btop --utf-force"))
        ws.tabs[0].splitRoot = .pane(pane)

        let file = LayoutSerializer.layout(for: ws, projectName: "api", projectRoot: root)
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.run == "btop --utf-force")
        #expect(p.cwd == nil)
        #expect(p.shell == nil)
    }

    @Test
    func omits_run_for_remote_pane_idle_at_its_prompt() {
        // The probe reporting the session's shell means an idle prompt —
        // nothing to record, same as a local idle pane.
        let root = "devbox:~/dev/api"
        let ws = Workspace(projectID: UUID(), projectPath: root)
        let pane = Pane(projectPath: root, projectID: ws.projectID)
        pane.applyRemoteForeground(RemoteForeground(comm: "-zsh", command: "-zsh"))
        ws.tabs[0].splitRoot = .pane(pane)

        let file = LayoutSerializer.layout(for: ws, projectName: "api", projectRoot: root)
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.run == nil)
    }

    @Test
    func records_live_running_command_per_pane() {
        // Save records what the pane is *currently* running (its live foreground
        // command), not what it was spawned with.
        let ws = Workspace(projectID: UUID(), projectPath: "/proj")
        ws.tabs[0].splitRoot = .pane(Pane(projectPath: "/proj", projectID: ws.projectID))

        let file = LayoutSerializer.layout(for: ws, projectName: "proj", projectRoot: "/proj", liveCommand: { _ in "btop" })
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.run == "btop")
    }

    @Test
    func omits_run_for_idle_pane() {
        // Pane idle at a prompt (no live command) → no run, even if it was
        // spawned with one.
        let ws = Workspace(projectID: UUID(), projectPath: "/proj")
        ws.tabs[0].splitRoot = .pane(Pane(projectPath: "/proj", projectID: ws.projectID, command: "btop"))

        let file = LayoutSerializer.layout(for: ws, projectName: "proj", projectRoot: "/proj", liveCommand: { _ in nil })
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.run == nil)
    }

    @Test
    func records_live_shell_when_pane_sits_in_one() {
        // A pane the user dropped into a non-default shell (e.g. `zsh` from `nu`)
        // saves that shell as `shell:`.
        let ws = Workspace(projectID: UUID(), projectPath: "/proj")
        ws.tabs[0].splitRoot = .pane(Pane(projectPath: "/proj", projectID: ws.projectID))

        let file = LayoutSerializer.layout(
            for: ws,
            projectName: "proj",
            projectRoot: "/proj",
            liveCommand: { _ in nil },
            liveShell: { _ in "/bin/zsh" }
        )
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.shell == "/bin/zsh")
        #expect(p.run == nil)
    }

    @Test
    func omits_shell_when_pane_is_in_default_shell() {
        // Idle in the default login shell → no shell recorded (liveShell returns
        // nil for the default), so the layout stays portable.
        let ws = Workspace(projectID: UUID(), projectPath: "/proj")
        ws.tabs[0].splitRoot = .pane(Pane(projectPath: "/proj", projectID: ws.projectID))

        let file = LayoutSerializer.layout(
            for: ws,
            projectName: "proj",
            projectRoot: "/proj",
            liveCommand: { _ in nil },
            liveShell: { _ in nil }
        )
        guard case let .pane(p) = file.tabs[0].layout else {
            Issue.record("expected leaf")
            return
        }
        #expect(p.shell == nil)
    }

    @Test
    func save_then_load_round_trips_topology_through_the_central_store() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("layout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path
        let store = ProjectFileStore(directoryURL: dir.appendingPathComponent("projects"))

        let ws = Workspace(projectID: UUID(), projectPath: root)
        ws.tabs[0].splitRoot = .split(SplitBranch(
            direction: .vertical,
            ratio: 0.4,
            first: .pane(Pane(projectPath: root, projectID: ws.projectID, command: "npm run dev")),
            second: .pane(Pane(projectPath: root, projectID: ws.projectID))
        ))

        let layout = LayoutSerializer.layout(for: ws, projectName: "proj", projectRoot: root, liveCommand: { $0.command })
        try store.write(ProjectFile(name: "proj", path: root, tabs: layout.tabs), projectName: "proj")
        let loaded = try #require(try store.loadFull(forProjectPath: root))

        #expect(loaded.path == root)
        guard case let .split(b) = loaded.tabs?[0].layout else {
            Issue.record("expected split")
            return
        }
        #expect(b.direction == .vertical)
        #expect(b.ratio == 0.4)
        guard case let .pane(first) = b.first else { Issue.record("expected leaf")
            return
        }
        #expect(first.run == "npm run dev")
    }
}
