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
            == "root: export: my-var is not a variable name that sh can read")
        #expect(Self
            .invalidMessage(
                "name: X\nnodes: { root: { items: [{ title: A, export: { MACTERM_PALETTE_COMMAND: x }, action: { copy: a } }] } }"
            )
            == "root item 1 (A): export: MACTERM_PALETTE_COMMAND is set by Macterm. Use another name")
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

    /// `when:` on the palette and on an item: a command, and the reason a
    /// muted row shows — "Unavailable" unless the file says.
    @Test
    func when_is_a_command_and_a_reason_on_the_palette_and_its_items() throws {
        let palette = try Self.palette("""
        name: K8s
        when: { run: kubectl get --raw /readyz, unavailable: Cluster unreachable }
        nodes:
          root:
            items:
              - { title: Pods, enter: root, when: { run: kubectl version } }
              - { title: Contexts, enter: root }
        """)
        #expect(palette.condition == CustomPaletteCondition(command: "kubectl get --raw /readyz", reason: "Cluster unreachable"))
        let items = try #require(palette.nodes["root"]?.items)
        #expect(items[0].condition == CustomPaletteCondition(command: "kubectl version", reason: "Unavailable"))
        #expect(items[1].condition == nil)

        #expect(Self.invalidMessage("name: X\nwhen: { run: \"  \" }\nnodes: { root: { items: [] } }") == "when: run: must not be empty")
        #expect(Self.invalidMessage("name: X\nwhen: { run: x, unavailabel: y }\nnodes: { root: { items: [] } }")
            == "when: unavailabel: no such key")
        #expect(Self.invalidMessage("name: X\nnodes: { root: { items: [{ title: A, enter: root, when: { run: y, cmd: x } }] } }")
            == "root item 1 (A): when: cmd: no such key")
        #expect(
            Self.invalidMessage("name: X\nnodes: { root: { list: ls, when: { run: x }, action: { copy: . } } }")
                == "root: when: no such key",
            "a listing's rows aren't checked one by one"
        )
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
        #expect(CustomPaletteFile.conditionKeys == properties(defs["condition"]))
    }

    @Test
    func every_mistake_is_named_with_its_node_and_field() {
        #expect(Self.invalidMessage("name: X\nrequires: [kubectl jq]\nnodes: { root: { items: [] } }")
            == "requires: kubectl jq is not a program name")
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
            == "root item 1 (A): has both enter: and action:. Use only one")
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
    /// captioned with a path in the `palettes/` folder of an extension in
    /// `~/.config/macterm/extensions/`, keyed by the file's stem. Read from
    /// the source tree, like `DocsLinkTests`, so a copy-pasted example that
    /// no longer reads fails here first.
    static func docsExamples() throws -> [String: String] {
        try captionedBlocks(#/^```yaml title="~/\.config/macterm/extensions/[a-z0-9-]+/palettes/([a-z0-9-]+)\.yaml"$/#)
    }

    /// Every `extension.yaml` the docs show, keyed by its extension's folder.
    static func docsManifests() throws -> [String: String] {
        try captionedBlocks(#/^```yaml title="~/\.config/macterm/extensions/([a-z0-9-]+)/extension\.yaml"$/#)
    }

    private static func captionedBlocks(_ caption: Regex<(Substring, Substring)>) throws -> [String: String] {
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
                } else if let match = line.firstMatch(of: caption) {
                    current = (String(match.output.1), [])
                }
            }
        }
        return examples
    }

    /// The extensions anyone can install from Settings → Extensions
    /// (`extensions/` at the repo root, a folder each): each has a manifest
    /// with its name, description and authors, a README, and palettes in
    /// `palettes/` that read through the validator and say what they are — a
    /// description, the programs they need — and holds nothing but text and a
    /// few screenshots of one exact size.
    @Test
    func every_extension_in_the_repo_reads_and_says_what_it_is() throws {
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extensions", isDirectory: true)
        let names = try fm.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(names.contains("README.md"))
        let ids = names.filter { $0 != "README.md" }.sorted()
        #expect(!ids.isEmpty)
        for id in ids {
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                Issue.record("\(id): only folders sit beside the README")
                continue
            }
            #expect(MactermExtension.isID(id), "\(id): an id is lowercase words joined by -")
            let text = { (name: String) in (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }
            do {
                let manifest = try ExtensionManifest.parse(yaml: text(MactermExtension.manifestName))
                #expect(!manifest.authors.isEmpty, "\(id): authors: names at least one GitHub username")
            } catch {
                Issue.record("\(id)/\(MactermExtension.manifestName) doesn't read: \(error.localizedDescription)")
            }
            #expect(MactermExtension.summary(readme: text(MactermExtension.readmeName)) != nil, "\(id): a README saying what it does")
            let palettesFolder = folder.appendingPathComponent(MactermExtension.palettesFolder, isDirectory: true)
            let palettes = (try? fm.contentsOfDirectory(atPath: palettesFolder.path)) ?? []
            #expect(!palettes.isEmpty, "\(id): at least one palette in \(MactermExtension.palettesFolder)/")
            for file in palettes.sorted() {
                let path = "\(MactermExtension.palettesFolder)/\(file)"
                guard MactermExtension.isPalette(path) else {
                    Issue.record("\(id)/\(path): only .yaml palettes go in \(MactermExtension.palettesFolder)/")
                    continue
                }
                do {
                    let palette = try Self.palette(text(path), id: MactermExtension.paletteID(extensionID: id, path: path))
                    #expect(palette.description?.isEmpty == false, "\(id)/\(path): a description")
                    #expect(!palette.requires.isEmpty, "\(id)/\(path): requires: names the programs it needs")
                } catch {
                    Issue.record("\(id)/\(path) doesn't read: \(error.localizedDescription)")
                }
            }
            var screenshots = 0
            let root = folder.standardizedFileURL.path + "/"
            for case let file as URL in fm
                .enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) ?? .init()
            {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let path = String(file.standardizedFileURL.path.dropFirst(root.count))
                let name = "\(id)/\(path)"
                #expect((values.fileSize ?? 0) <= MactermExtension.maxFileSize, "\(name): under 500 KB")
                let data = try Data(contentsOf: file)
                if MactermExtension.isScreenshot(path) {
                    screenshots += 1
                    let size = MactermExtension.pngSize(data)
                    let want = MactermExtension.screenshotPixelSize
                    #expect(
                        size?.width == want.width && size?.height == want.height,
                        "\(name): a screenshot is a \(want.width)×\(want.height) PNG — take it with Capture Palette Screenshot"
                    )
                } else {
                    #expect(
                        String(data: data, encoding: .utf8) != nil,
                        "\(name): text — the only images are PNG screenshots in \(MactermExtension.screenshotsFolder)/"
                    )
                }
            }
            #expect(screenshots <= MactermExtension.maxScreenshots, "\(id): at most \(MactermExtension.maxScreenshots) screenshots")
        }
    }

    @Test
    func every_extension_manifest_in_the_docs_reads() throws {
        let manifests = try Self.docsManifests()
        #expect(!manifests.isEmpty)
        for (id, yaml) in manifests {
            #expect(throws: Never.self, "the docs' \(id)/extension.yaml doesn't read") {
                try ExtensionManifest.parse(yaml: yaml)
            }
        }
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
