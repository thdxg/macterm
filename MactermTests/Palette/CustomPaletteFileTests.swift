import Foundation
@testable import Macterm
import Testing

/// The palette file (`CustomPaletteFile`): what parses, what validates,
/// and what each mistake is called.
struct CustomPaletteFileTests {
    static let kubernetes = """
    name: Kubernetes
    icon: shippingbox
    description: Namespaces, pods and their logs
    root: menu
    nodes:
      menu:
        items:
          - { title: Namespaces, enter: namespaces }
          - { title: Pods, subtitle: All namespaces, enter: pods }
      namespaces:
        list: kubectl get ns -o json
        rows: .items
        title: .metadata.name
        export: { NAMESPACE: .metadata.name }
        enter: namespace-menu
      namespace-menu:
        items:
          - { title: Pods, enter: pods }
          - { title: Set as current context, action: { run: kubectl config set-context --current --namespace "$NAMESPACE" } }
      pods:
        list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
        rows: .items
        title: .metadata.name
        subtitle: .status.phase
        match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
        export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
        action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
    """

    static func palette(_ yaml: String, id: String = "test") throws -> CustomPalette {
        try CustomPalette(file: CustomPaletteFile.parse(yaml: yaml), id: id)
    }

    static func invalidMessage(_ yaml: String) -> String? {
        do {
            _ = try palette(yaml)
            return nil
        } catch let error as CustomPaletteError {
            return error.errorDescription
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test
    func the_kubernetes_example_validates_into_menus_and_listings() throws {
        let palette = try Self.palette(Self.kubernetes, id: "kubernetes")
        #expect(palette.id == "kubernetes")
        #expect(palette.name == "Kubernetes")
        #expect(palette.icon == "shippingbox")
        #expect(palette.root == "menu")
        #expect(Set(palette.nodes.keys) == ["menu", "namespaces", "namespace-menu", "pods"])

        guard case let .menu(items)? = palette.nodes["menu"]?.kind else { Issue.record("menu is not a menu")
            return
        }
        #expect(items.map(\.title) == ["Namespaces", "Pods"])
        #expect(items[0].outcome == .enter(node: "namespaces"))
        #expect(items[1].subtitle == "All namespaces")

        guard case let .listing(namespaces)? = palette.nodes["namespaces"]?.kind else { Issue.record("namespaces is not a listing")
            return
        }
        #expect(namespaces.command == "kubectl get ns -o json")
        #expect(namespaces.rowsPath == ".items")
        #expect(namespaces.title == ".metadata.name")
        #expect(namespaces.match == [".metadata.name"], "match defaults to the title (and subtitle)")
        #expect(namespaces.exports == ["NAMESPACE": ".metadata.name"])
        #expect(namespaces.outcome == .enter(node: "namespace-menu"))

        guard case let .listing(pods)? = palette.nodes["pods"]?.kind else { Issue.record("pods is not a listing")
            return
        }
        #expect(pods.match == [".metadata.name", ".metadata.namespace", ".metadata.labels.app"])
        #expect(pods.outcome == .perform(.run(command: "kubectl logs -f -n \"$NAMESPACE\" \"$POD\"", in: .split)))

        guard case let .menu(contextItems)? = palette.nodes["namespace-menu"]?.kind else { return }
        #expect(
            contextItems[1].outcome == .perform(.run(command: "kubectl config set-context --current --namespace \"$NAMESPACE\"", in: .tab)),
            "in: defaults to a new tab"
        )
    }

    @Test
    func a_node_called_root_is_the_default_root_and_the_icon_has_a_default() throws {
        let palette = try Self.palette("""
        name: Branches
        nodes:
          root:
            list: git branch --format='%(refname:short)'
            action: { run: git switch "$BRANCH" }
            export: { BRANCH: . }
        """)
        #expect(palette.root == "root")
        #expect(palette.icon == CustomPalette.defaultIcon)
        guard case let .listing(listing)? = palette.nodes["root"]?.kind else { return }
        #expect(listing.title == ".", "plain lines: the title is the line")
        #expect(listing.match == ["."])
    }

    @Test
    func every_mistake_is_named_with_its_node_and_field() {
        #expect(Self.invalidMessage("name: ''\nnodes: { root: { items: [] } }") == "name: must not be empty")
        #expect(Self.invalidMessage("name: X\nnodes: {}") == "nodes: must name at least one node")
        #expect(Self.invalidMessage("name: X\nnodes: { menu: { items: [] } }")
            == "root: names no node (add a node called root, or set root:)")
        #expect(Self.invalidMessage("name: X\nroot: nope\nnodes: { menu: { items: [] } }") == "root: no node named nope")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { placeholder: hi } }")
            == "root: needs items: (a menu) or list: (a command)")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [], list: ls } }")
            == "root: has both items: and list:; a node is one or the other")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A }] } }")
            == "root item 1 (A): needs enter: or action:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, enter: pods }] } }")
            == "root item 1 (A): enter: no node named pods")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, enter: root, action: { copy: x } }] } }")
            == "root item 1 (A): has both enter: and action:; pick one")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { copy: x, open: y } } }")
            == "root: action needs exactly one of run:, copy:, open:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { run: x, in: window } } }")
            == "root: in: must be tab or split, not window")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls } }") == "root: needs enter: or action:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, action: { copy: a } }], title: .x } }")
            == "root: title: belongs to a list: node, not a menu")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, action: { copy: a } }], enter: root } }")
            == "root: enter:/action: go on each item of a menu")
    }

    @Test
    func yaml_that_does_not_parse_is_a_parse_error() {
        #expect(throws: CustomPaletteError.self) {
            try CustomPaletteFile.parse(yaml: "name: [unclosed")
        }
        #expect(throws: CustomPaletteError.self) {
            try CustomPaletteFile.parse(yaml: "nodes: {}")
        }
    }

    // MARK: - The docs' examples

    /// Every complete palette file the docs show: a fenced `yaml` block
    /// captioned with a path in `~/.config/macterm/palettes/`, keyed by the
    /// file's stem. Read from the source tree, like `DocsLinkTests`, so a
    /// copy-pasted example that no longer reads fails here first.
    static func docsExamples() throws -> [String: String] {
        let pages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Palette
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("website/docs/pages")
        var examples: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
            where file.pathExtension == "md"
        {
            var current: (id: String, lines: [String])?
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                if let open = current {
                    if line == "```" {
                        examples[open.id] = open.lines.joined(separator: "\n")
                        current = nil
                    } else {
                        current?.lines.append(line)
                    }
                } else if let match = line.firstMatch(of: #/^```yaml title="~/\.config/macterm/palettes/([a-z0-9-]+)\.yaml"$/#) {
                    current = (String(match.output.1), [])
                }
            }
        }
        return examples
    }

    @Test
    func every_palette_file_in_the_docs_reads() throws {
        let examples = try Self.docsExamples()
        #expect(Set(examples.keys) == ["git", "docker", "ssh", "kubernetes"])
        for (id, yaml) in examples {
            #expect(throws: Never.self, "the docs' \(id).yaml doesn't read") {
                try Self.palette(yaml, id: id)
            }
        }
    }

    @Test
    func the_cookbook_kubernetes_palette_reads_a_port_by_index_and_a_namespace_from_above() throws {
        let palette = try Self.palette(#require(Self.docsExamples()["kubernetes"]), id: "kubernetes")
        guard case let .listing(services)? = palette.nodes["services"]?.kind else {
            Issue.record("services is not a listing")
            return
        }
        let output = #"{"items":[{"metadata":{"name":"api","namespace":"prod"},"spec":{"type":"ClusterIP","ports":[{"port":8080}]}}]}"#
        let rows = try CustomPaletteRows.parse(output: output, listing: services)
        #expect(rows.map(\.exports) == [["SERVICE": "api", "NAMESPACE": "prod", "PORT": "8080"]])

        guard case let .listing(pods)? = palette.nodes["pods"]?.kind else {
            Issue.record("pods is not a listing")
            return
        }
        #expect(pods.command.contains(#"set -- -n "$NAMESPACE""#), "a namespace picked above scopes the listing")
        #expect(pods.outcome == .enter(node: "pod-menu"))
    }
}
