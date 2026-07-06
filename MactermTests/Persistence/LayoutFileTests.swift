import Foundation
@testable import Macterm
import Testing

@MainActor
struct LayoutFileTests {
    @Test
    func parses_nested_layout_with_processes() throws {
        let yaml = """
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              ratio: 0.6
              first:
                cwd: "./api"
                run: "npm run dev"
                shell: /bin/zsh
              second:
                split:
                  direction: vertical
                  first:  { cwd: "./api", run: "npm test" }
                  second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        #expect(file.tabs.count == 1)

        guard case let .split(outer) = file.tabs[0].layout else {
            Issue.record("expected outer split")
            return
        }
        #expect(outer.direction == .horizontal)
        #expect(outer.ratio == 0.6)

        guard case let .pane(first) = outer.first else {
            Issue.record("expected leaf")
            return
        }
        #expect(first.cwd == "./api")
        #expect(first.run == "npm run dev")
        #expect(first.shell == "/bin/zsh")

        guard case let .split(inner) = outer.second, case let .pane(shell) = inner.second else {
            Issue.record("expected inner split with plain shell")
            return
        }
        #expect(inner.direction == .vertical)
        #expect(shell.run == nil)
    }

    @Test
    func ratio_defaults_to_even_split_when_omitted() throws {
        let yaml = """
        tabs:
          - split:
              direction: vertical
              first: { }
              second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        guard case let .split(b) = file.tabs[0].layout else {
            Issue.record("expected split")
            return
        }
        #expect(b.ratio == nil)
        #expect(b.resolvedRatio == 0.5)
    }

    @Test
    func split_missing_a_child_is_rejected() {
        // A `split:` mapping must carry both `first` and `second`; one missing
        // is malformed.
        let yaml = """
        tabs:
          - split:
              direction: horizontal
              first: { run: "npm run dev" }
        """
        #expect(throws: (any Error).self) { try LayoutFile.parse(yaml: yaml) }
    }

    @Test
    func builds_split_node_tree_resolving_cwd_and_command() throws {
        let yaml = """
        tabs:
          - name: "T"
            split:
              direction: horizontal
              first:  { cwd: "api", run: "npm run dev" }
              second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        // Build via the reconciler (the live apply path) against no workspace,
        // so every leaf is freshly spawned from the declaration.
        let plan = LayoutReconciler.plan(layout: file, workspace: nil, projectRoot: "/proj", projectID: UUID())
        #expect(plan.tabs.count == 1)
        let panes = plan.tabs[0].root.allPanes()
        #expect(panes.count == 2)
        #expect(panes[0].command == "npm run dev")
        #expect(panes[0].projectPath == "/proj/api")
        #expect(panes[1].command == nil)
        #expect(panes[1].projectPath == "/proj")
    }

    @Test
    func cwd_resolution_handles_absolute_relative_and_nil() {
        #expect(LayoutBuilder.resolveCwd(nil, projectRoot: "/proj") == "/proj")
        #expect(LayoutBuilder.resolveCwd("", projectRoot: "/proj") == "/proj")
        #expect(LayoutBuilder.resolveCwd("/abs/path", projectRoot: "/proj") == "/abs/path")
        #expect(LayoutBuilder.resolveCwd("sub/dir", projectRoot: "/proj") == "/proj/sub/dir")
    }

    @Test
    func cwd_resolution_against_a_remote_root_is_string_only() {
        // Remote roots (#104): no local filesystem semantics. `~` must stay
        // remote-home (never the local user's), relatives join the root's
        // directory, and the [user@]host: prefix survives so the pane stays
        // remote.
        let root = "me@devbox:~/dev/api"
        #expect(LayoutBuilder.resolveCwd(nil, projectRoot: root) == root)
        #expect(LayoutBuilder.resolveCwd("sub/dir", projectRoot: root) == "me@devbox:~/dev/api/sub/dir")
        #expect(LayoutBuilder.resolveCwd("/srv/logs", projectRoot: root) == "me@devbox:/srv/logs")
        #expect(LayoutBuilder.resolveCwd("~/other", projectRoot: root) == "me@devbox:~/other")
    }

    @Test
    func built_tab_focuses_its_first_pane() throws {
        let yaml = """
        tabs:
          - split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        let plan = LayoutReconciler.plan(layout: file, workspace: nil, projectRoot: "/proj", projectID: UUID())
        #expect(plan.tabs[0].focusedPaneID == plan.tabs[0].root.allPanes().first?.id)
    }

    @Test
    func yaml_round_trips_through_encode_decode() throws {
        let original = LayoutFile(
            name: "MyApp",
            tabs: [LayoutTab(name: "Dev", layout: .split(LayoutBranch(
                direction: .horizontal,
                ratio: 0.6,
                first: .pane(LayoutPane(cwd: "./api", run: "npm run dev", shell: "/bin/zsh")),
                second: .pane(LayoutPane(cwd: nil, run: nil, shell: nil))
            )))]
        )
        let yaml = try original.yaml()
        // Saved files carry the schema modeline for editor support; it's a YAML
        // comment, so it must not affect the round-trip.
        #expect(yaml.hasPrefix("# yaml-language-server: $schema="))
        #expect(try LayoutFile.parse(yaml: yaml) == original)
    }
}
