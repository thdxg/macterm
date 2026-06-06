import Foundation
@testable import Macterm
import Testing

@MainActor
struct LayoutFileTests {
    @Test
    func parses_nested_layout_with_processes() throws {
        let yaml = """
        shell: /bin/zsh
        tabs:
          - name: "Dev"
            layout:
              split: horizontal
              ratio: 0.6
              first:
                cwd: "./api"
                run: "npm run dev"
              second:
                split: vertical
                first:  { cwd: "./api", run: "npm test" }
                second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        #expect(file.shell == "/bin/zsh")
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
          - layout:
              split: vertical
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
    func first_second_without_split_is_rejected() {
        // `first`/`second` only mean something on a split node; a leaf carrying
        // them (no `split` direction) is malformed.
        let yaml = """
        tabs:
          - layout:
              first: { }
              second: { }
        """
        #expect(throws: (any Error).self) { try LayoutFile.parse(yaml: yaml) }
    }

    @Test
    func builds_split_node_tree_resolving_cwd_and_command() throws {
        let yaml = """
        tabs:
          - name: "T"
            layout:
              split: horizontal
              first:  { cwd: "api", run: "npm run dev" }
              second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        let projectID = UUID()
        let tabs = LayoutBuilder.buildTabs(file, projectRoot: "/proj", projectID: projectID)
        #expect(tabs.count == 1)
        let panes = tabs[0].splitRoot.allPanes()
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
    func built_tab_focuses_its_first_pane() throws {
        let yaml = """
        tabs:
          - layout:
              split: horizontal
              first:  { run: "npm run dev" }
              second: { }
        """
        let file = try LayoutFile.parse(yaml: yaml)
        let tabs = LayoutBuilder.buildTabs(file, projectRoot: "/proj", projectID: UUID())
        #expect(tabs[0].focusedPaneID == tabs[0].splitRoot.allPanes().first?.id)
    }

    @Test
    func yaml_round_trips_through_encode_decode() throws {
        let original = LayoutFile(
            name: "MyApp",
            shell: "/bin/zsh",
            tabs: [LayoutTab(name: "Dev", layout: .split(LayoutBranch(
                direction: .horizontal,
                ratio: 0.6,
                first: .pane(LayoutPane(cwd: "./api", run: "npm run dev", shell: nil)),
                second: .pane(LayoutPane(cwd: nil, run: nil, shell: nil))
            )))]
        )
        let decoded = try LayoutFile.parse(yaml: original.yaml())
        #expect(decoded == original)
    }
}
