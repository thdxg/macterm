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

        guard let items = palette.nodes["menu"]?.items, palette.nodes["menu"]?.listing == nil else { Issue.record("menu is not a menu")
            return
        }
        #expect(items.map(\.title) == ["Namespaces", "Pods"])
        #expect(items[0].outcome == .enter(node: "namespaces"))
        #expect(items[1].subtitle == "All namespaces")

        guard let namespaces = palette.nodes["namespaces"]?.listing else { Issue.record("namespaces is not a listing")
            return
        }
        #expect(namespaces.command == "kubectl get ns -o json")
        #expect(namespaces.rowsPath == ".items")
        #expect(namespaces.title == ".metadata.name")
        #expect(namespaces.match == [".metadata.name"], "match defaults to the title (and subtitle)")
        #expect(namespaces.exports == ["NAMESPACE": ".metadata.name"])
        #expect(namespaces.outcome == .enter(node: "namespace-menu"))

        guard let pods = palette.nodes["pods"]?.listing else { Issue.record("pods is not a listing")
            return
        }
        #expect(pods.match == [".metadata.name", ".metadata.namespace", ".metadata.labels.app"])
        #expect(pods.outcome == .perform(.run(command: "kubectl logs -f -n \"$NAMESPACE\" \"$POD\"", in: .split)))

        guard let contextItems = palette.nodes["namespace-menu"]?.items, palette.nodes["namespace-menu"]?.listing == nil else { return }
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
        guard let listing = palette.nodes["root"]?.listing else { return }
        #expect(listing.title == ".", "plain lines: the title is the line")
        #expect(listing.match == ["."])
    }

    @Test
    func a_node_can_have_items_and_a_listing_and_any_row_an_alt_action() throws {
        let palette = try Self.palette("""
        name: Sessions
        nodes:
          root:
            items:
              - { title: New, action: { run: claude }, alt: { title: New in a Split, run: claude, in: split } }
              - { title: All, enter: all }
            list: ls
            export: { SESSION: . }
            action: { run: claude --resume "$SESSION" }
            alt: { copy: . }
          all:
            list: ls
            action: { run: claude }
        """)
        let root = try #require(palette.nodes["root"])
        #expect(root.items.map(\.title) == ["New", "All"])
        #expect(try root.items[0].alt == CustomPaletteAlt(.init(title: "New in a Split", run: "claude", in: "split"), at: "x"))
        #expect(root.items[0].alt?.title == "New in a Split")
        #expect(root.items[1].alt == nil)
        #expect(root.listing?.alt?.action == .copy("."))
        #expect(root.listing?.alt?.title == "Copy", "an untitled alt is named after what it does")
        #expect(palette.nodes["all"]?.items.isEmpty == true)
    }

    @Test
    func requires_names_the_programs_and_defaults_to_none() throws {
        #expect(try Self.palette(Self.kubernetes).requires.isEmpty)
        let palette = try Self.palette("""
        name: Pods
        requires: [kubectl, jq]
        nodes: { root: { list: kubectl get pods -o name, action: { copy: . } } }
        """)
        #expect(palette.requires == ["kubectl", "jq"])
    }

    /// A key no level takes is a mistake like any other, named where it is —
    /// the decoder alone drops it, and a misspelled `subtitel:` silently did
    /// nothing.
    @Test
    func a_key_nothing_takes_is_named_where_it_is() {
        #expect(Self.invalidMessage("name: X\ndescripton: y\nnodes: { root: { items: [] } }") == "descripton: no such key")
        #expect(Self.invalidMessage("name: X\nnodes: { pods: { list: ls, mathc: [.], action: { copy: . } } }")
            == "pods: mathc: no such key")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, subtitel: b, action: { copy: a } }] } }")
            == "root item 1 (A): subtitel: no such key")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { run: x, inn: split } } }")
            == "root: action: inn: no such key")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, action: { copy: a }, alt: { copy: b, titel: c } }] } }")
            == "root item 1 (A): alt: titel: no such key")
        #expect(
            Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { title: T, run: x } } }")
                == "root: title: goes on alt:, not action:",
            "a key that exists elsewhere keeps its own message"
        )
    }

    /// Rules the decoder can't see: where `in:` goes, a `match:` that
    /// could match nothing, and export names `sh` can't read or Macterm
    /// sets itself.
    @Test
    func in_match_and_export_names_are_checked() {
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { copy: ., in: split } } }")
            == "root: in: split goes with run:, not copy: or open:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, match: [], action: { copy: . } } }")
            == "root: match: needs at least one field, or leave it out")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, export: { my-var: . }, action: { copy: . } } }")
            == "root: export: my-var isn't a variable name sh can read")
        #expect(Self
            .invalidMessage(
                "name: X\nnodes: { root: { items: [{ title: A, export: { MACTERM_PALETTE_COMMAND: x }, action: { copy: a } }] } }"
            )
            == "root item 1 (A): export: MACTERM_PALETTE_COMMAND is set by Macterm; pick another name")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, export: { _NS1: . }, action: { copy: . } } }") == nil)
    }

    /// A node named like a number or a boolean is still a name, and its keys
    /// are still checked — read as the decoder reads them.
    @Test
    func a_node_named_like_a_number_still_has_its_keys_checked() {
        #expect(Self.invalidMessage("name: X\nroot: \"404\"\nnodes: { 404: { list: ls, mathc: [.], action: { copy: . } } }")
            == "404: mathc: no such key")
        #expect(Self.invalidMessage("name: X\nroot: \"on\"\nnodes: { on: { list: ls, action: { copy: . } } }") == nil)
    }

    /// The keys each level takes are the schema's, so an editor validating
    /// against it and Macterm agree on what a file may say.
    @Test
    func the_keys_each_level_takes_are_the_schemas() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/palette.schema.json")
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func properties(_ object: Any?) -> Set<String> {
            Set(((object as? [String: Any])?["properties"] as? [String: Any] ?? [:]).keys)
        }
        let defs = try #require(schema["$defs"] as? [String: Any])
        #expect(CustomPaletteFile.fileKeys == properties(schema))
        #expect(CustomPaletteFile.nodeKeys == properties(defs["node"]))
        #expect(CustomPaletteFile.itemKeys == properties(defs["item"]))
        #expect(CustomPaletteFile.actionKeys == properties(defs["actionFields"]).union(properties(defs["alt"])))
    }

    @Test
    func every_mistake_is_named_with_its_node_and_field() {
        #expect(Self.invalidMessage("name: X\nrequires: [kubectl jq]\nnodes: { root: { items: [] } }")
            == "requires: kubectl jq isn't a program name")
        #expect(Self.invalidMessage("name: ''\nnodes: { root: { items: [] } }") == "name: must not be empty")
        #expect(Self.invalidMessage("name: X\nnodes: {}") == "nodes: must name at least one node")
        #expect(Self.invalidMessage("name: X\nnodes: { menu: { items: [] } }")
            == "root: names no node (add a node called root, or set root:)")
        #expect(Self.invalidMessage("name: X\nroot: nope\nnodes: { menu: { items: [] } }") == "root: no node named nope")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { placeholder: hi } }")
            == "root: needs items: (rows written out) or list: (a command)")
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
            == "root: title: belongs to a list: node")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, action: { copy: a } }], enter: root } }")
            == "root: enter:/action:/alt: go on each item, or with a list:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { run: x }, alt: { run: y, in: door } } }")
            == "root: alt: in: must be tab or split, not door")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { list: ls, action: { title: T, run: x } } }")
            == "root: title: goes on alt:, not action:")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, action: { copy: a }, alt: { copy: b, open: c } }] } }")
            == "root item 1 (A): alt: action needs exactly one of run:, copy:, open:")
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
        guard let services = palette.nodes["services"]?.listing else {
            Issue.record("services is not a listing")
            return
        }
        let output = #"{"items":[{"metadata":{"name":"api","namespace":"prod"},"spec":{"type":"ClusterIP","ports":[{"port":8080}]}}]}"#
        let rows = try CustomPaletteRows.parse(output: output, listing: services)
        #expect(rows.map(\.exports) == [["SERVICE": "api", "NAMESPACE": "prod", "PORT": "8080"]])

        guard let pods = palette.nodes["pods"]?.listing else {
            Issue.record("pods is not a listing")
            return
        }
        #expect(pods.command.contains(#"set -- -n "$NAMESPACE""#), "a namespace picked above scopes the listing")
        #expect(pods.outcome == .enter(node: "pod-menu"))
    }
}
