import Foundation
@testable import Macterm
import Testing

/// The extensions anyone can install (`PaletteRegistry`), the store reading
/// them once installed, and Settings → Palettes' cards over both
/// (`PaletteGalleryItem`), with GitHub served from memory.
@MainActor
struct PaletteRegistryTests {
    private static let kubernetes = """
    name: Kubernetes
    description: Browse clusters
    icon: shippingbox
    requires: [kubectl]
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let fromTheFuture = """
    name: Future
    someNewKey: true
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let manifest = "authors: [thdxg]\n"
    private static let readme = "# Kubernetes\n\nBrowse a cluster's pods.\n\nNeeds `kubectl`.\n"

    /// GitHub's tree of `extensions/`, as the API returns it.
    private static func tree(_ files: [(path: String, mode: String)]) -> Data {
        var items: [[String: Any]] = []
        var folders = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/")
            if parts.count > 1, folders.insert(String(parts[0])).inserted {
                items.append(["path": String(parts[0]), "mode": "040000", "type": "tree", "sha": "0"])
            }
            items.append(["path": file.path, "mode": file.mode, "type": "blob", "sha": "0", "size": 10])
        }
        return (try? JSONSerialization.data(withJSONObject: ["sha": "0", "tree": items, "truncated": false])) ?? Data()
    }

    /// A fetch answering from `responses` by URL, counting the tree reads.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: (Data, Int)] = [:]
        private var trees = 0
        var treeReads: Int { lock.withLock { trees } }

        var fetch: PaletteRegistry.Fetch {
            { [self] url in
                lock.withLock {
                    if url.host == "api.github.com" { trees += 1 }
                    return responses[url.absoluteString] ?? (Data(), 404)
                }
            }
        }

        func serve(ref: String, id: String, _ path: String, _ text: String) {
            serve(ref: ref, id: id, path, Data(text.utf8))
        }

        func serve(ref: String, id: String, _ path: String, _ data: Data) {
            responses[PaletteRegistry.fileURL(ref: ref, id: id, path: path).absoluteString] = (data, 200)
        }
    }

    private func settle() async {
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeStore() throws -> CustomPaletteStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-registry-\(UUID().uuidString)", isDirectory: true)
        return CustomPaletteStore(directoryURL: dir.appendingPathComponent("palettes", isDirectory: true))
    }

    private static func entry(_ id: String, palette: String, manifest: String = manifest) -> PaletteRegistry.Entry {
        PaletteRegistry.Entry(
            id: id,
            files: [
                .init(path: "README.md", size: 10, executable: false),
                .init(path: "extension.yaml", size: 10, executable: false),
                .init(path: "palette.yaml", size: 10, executable: false),
            ],
            texts: ["README.md": readme, "extension.yaml": manifest, "palette.yaml": palette]
        )
    }

    @Test
    func a_build_reads_the_extensions_of_its_own_version() {
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm.debug", version: "0.0.0") == "main")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.31.2-tip.44") == "tip")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.32.0-beta.4") == "v1.32.0-beta.4")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.32.0") == "v1.32.0")
        #expect(PaletteRegistry.treeURL(ref: "v1.32.0").absoluteString
            == "https://api.github.com/repos/thdxg/macterm/git/trees/v1.32.0:extensions?recursive=1")
        #expect(PaletteRegistry.fileURL(ref: "main", id: "git", path: "palette.yaml").absoluteString
            == "https://raw.githubusercontent.com/thdxg/macterm/main/extensions/git/palette.yaml")
    }

    @Test
    func a_tree_yields_each_folder_with_a_palette_and_its_files() throws {
        let extensions = try PaletteRegistry.parseTree(Self.tree([
            ("README.md", "100644"),
            ("kubernetes/palette.yaml", "100644"),
            ("kubernetes/extension.yaml", "100644"),
            ("kubernetes/scripts/pods.sh", "100755"),
            ("draft/notes.md", "100644"),
        ]))
        #expect(extensions.map(\.id) == ["kubernetes"], "the top README and a folder without a palette are no extension")
        #expect(extensions.first?.files.map(\.path) == ["extension.yaml", "palette.yaml", "scripts/pods.sh"])
        #expect(extensions.first?.files.map(\.executable) == [false, false, true])
    }

    @Test
    func a_refresh_reads_every_extension_through_this_builds_validator_once_an_hour() async {
        let server = Server()
        let ref = "v1.32.0"
        server.responses[PaletteRegistry.treeURL(ref: ref).absoluteString] = (Self.tree([
            ("kubernetes/README.md", "100644"),
            ("kubernetes/extension.yaml", "100644"),
            ("kubernetes/palette.yaml", "100644"),
            ("kubernetes/shot.png", "100644"),
            ("future/extension.yaml", "100644"),
            ("future/palette.yaml", "100644"),
            ("nobody/extension.yaml", "100644"),
            ("nobody/palette.yaml", "100644"),
        ]), 200)
        server.serve(ref: ref, id: "kubernetes", "README.md", Self.readme)
        server.serve(ref: ref, id: "kubernetes", "extension.yaml", Self.manifest)
        server.serve(ref: ref, id: "kubernetes", "palette.yaml", Self.kubernetes)
        server.serve(ref: ref, id: "future", "extension.yaml", Self.manifest)
        server.serve(ref: ref, id: "future", "palette.yaml", Self.fromTheFuture)
        server.serve(ref: ref, id: "nobody", "extension.yaml", "authors: []\n")
        server.serve(ref: ref, id: "nobody", "palette.yaml", Self.kubernetes)
        let registry = PaletteRegistry(ref: ref, fetch: server.fetch)

        registry.refresh()
        #expect(registry.state == .loading)
        await settle()
        guard case .loaded = registry.state else {
            Issue.record("not loaded: \(registry.state)")
            return
        }
        #expect(registry.entries.map(\.id) == ["future", "kubernetes", "nobody"])
        let kubernetes = registry.entries[1]
        #expect(kubernetes.name == "Kubernetes")
        #expect(kubernetes.authors == ["thdxg"])
        #expect(kubernetes.readme == Self.readme)
        #expect(kubernetes.texts["shot.png"] == nil, "images wait for the install")
        #expect(kubernetes.failure == nil)
        #expect(registry.entries[0].failure?.errorDescription == "someNewKey: no such key", "a newer palette says why it can't be read")
        #expect(registry.entries[2].failure != nil, "a manifest naming nobody can't be installed")

        registry.refresh()
        await settle()
        #expect(server.treeReads == 1, "read once an hour")
        registry.refresh(force: true)
        await settle()
        #expect(server.treeReads == 2, "Refresh reads again")
    }

    @Test
    func a_version_without_extensions_says_so() async {
        let registry = PaletteRegistry(ref: "v1.0.0", fetch: Server().fetch)
        registry.refresh()
        await settle()
        #expect(registry.state == .failed("No extensions for this version (v1.0.0)."))
        #expect(registry.entries.isEmpty)
    }

    @Test
    func installing_copies_the_folder_in_and_never_replaces_a_palette() async throws {
        let store = try makeStore()
        let server = Server()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        server.serve(ref: "main", id: "kubernetes", "shot.png", png)
        let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
        let base = Self.entry("kubernetes", palette: Self.kubernetes)
        let entry = PaletteRegistry.Entry(
            id: "kubernetes",
            files: base.files + [
                .init(path: "scripts/pods.sh", size: 10, executable: true),
                .init(path: "shot.png", size: 4, executable: false),
            ],
            texts: base.texts.merging(["scripts/pods.sh": "#!/bin/sh\nkubectl get pods\n"]) { _, new in new }
        )

        let folder = try await registry.install(entry, into: store)
        #expect(folder == store.extensionsURL.appendingPathComponent("kubernetes", isDirectory: true))
        #expect(try String(contentsOf: folder.appendingPathComponent("palette.yaml"), encoding: .utf8) == Self.kubernetes)
        #expect(try Data(contentsOf: folder.appendingPathComponent("shot.png")) == png, "images are fetched at install")
        let mode = try FileManager.default
            .attributesOfItem(atPath: folder.appendingPathComponent("scripts/pods.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755, "a script stays executable")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.extensionsURL.path)
        #expect(leftovers == ["kubernetes"], "nothing staged is left behind")

        let installed = store.entry(id: "kubernetes")
        #expect(installed?.palette?.name == "Kubernetes", "installed at once")
        #expect(installed?.authors == ["thdxg"])
        #expect(installed?.extensionDirectory?.standardizedFileURL == folder.standardizedFileURL, "its commands get MACTERM_EXTENSION_DIR")

        await #expect(throws: PaletteRegistry.InstallError.alreadyInstalled("kubernetes")) {
            try await registry.install(entry, into: store)
        }
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try "name: Mine\nnodes: { root: { items: [] } }".write(
            to: store.directoryURL.appendingPathComponent("git.yml"), atomically: true, encoding: .utf8
        )
        store.reload()
        await #expect(throws: PaletteRegistry.InstallError.alreadyInstalled("git"), "a palette file of that name is the user's") {
            try await registry.install(Self.entry("git", palette: Self.kubernetes), into: store)
        }
        await #expect(throws: PaletteRegistry.InstallError.self, "an extension this build can't read isn't installed") {
            try await registry.install(Self.entry("future", palette: Self.fromTheFuture), into: store)
        }
        #expect(!FileManager.default.fileExists(atPath: store.extensionsURL.appendingPathComponent("future").path))
    }

    @Test
    func a_failed_download_installs_nothing() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let base = Self.entry("kubernetes", palette: Self.kubernetes)
        let entry = PaletteRegistry.Entry(
            id: "kubernetes",
            files: base.files + [.init(path: "shot.png", size: 4, executable: false)],
            texts: base.texts
        )
        await #expect(throws: PaletteRegistry.RegistryError.self) {
            try await registry.install(entry, into: store)
        }
        #expect(store.entry(id: "kubernetes") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.extensionsURL.appendingPathComponent("kubernetes").path))
    }

    @Test
    func a_palette_file_wins_over_an_extension_of_the_same_id() throws {
        let store = try makeStore()
        let folder = store.extensionsURL.appendingPathComponent("git", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Self.kubernetes.write(to: folder.appendingPathComponent("palette.yaml"), atomically: true, encoding: .utf8)
        try Self.manifest.write(to: folder.appendingPathComponent("extension.yaml"), atomically: true, encoding: .utf8)
        try Self.kubernetes.write(to: store.directoryURL.appendingPathComponent("git.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.entry(id: "git")?.extensionDirectory == nil, "the user's own file is the palette")
        #expect(store.entry(id: "extensions/git")?.failure != nil, "the extension says why it isn't")
    }

    @Test
    func a_manifest_names_its_authors_by_github_username() throws {
        #expect(try ExtensionManifest.parse(yaml: "authors: [thdxg, some-one]").authors == ["thdxg", "some-one"])
        #expect(throws: CustomPaletteError.self) { try ExtensionManifest.parse(yaml: "authors: []") }
        #expect(throws: CustomPaletteError.self) { try ExtensionManifest.parse(yaml: "authors: [-bad]") }
        #expect(throws: CustomPaletteError.self) { try ExtensionManifest.parse(yaml: "authors: [a]\nversion: 2") }
        #expect(MactermExtension.summary(readme: Self.readme) == "Browse a cluster's pods.")
        #expect(MactermExtension.isID("claude-code"))
        #expect(!MactermExtension.isID("Claude_Code"))
    }

    /// Built-in, then installed, then what the repository has that isn't
    /// installed — a repository palette already installed listed once, as
    /// installed — each section ranked by the search.
    @Test
    func the_gallery_lists_built_in_installed_and_available_palettes_once_each() throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Self.kubernetes.write(to: store.directoryURL.appendingPathComponent("kubernetes.yaml"), atomically: true, encoding: .utf8)
        try "name: Notes\ndescription: My own\nnodes: { root: { list: ls, action: { copy: . } } }"
            .write(to: store.directoryURL.appendingPathComponent("notes.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        let registry = [
            Self.entry("kubernetes", palette: Self.kubernetes),
            Self.entry("docker", palette: "name: Docker\ndescription: Containers\nnodes: { root: { list: ls, action: { copy: . } } }"),
        ]

        let all = PaletteGalleryItem.sections(builtIn: PaletteScopeID.builtIn, installed: store.entries, registry: registry, query: "")
        #expect(all.map(\.title) == ["Built-in", "Installed", "Available"])
        #expect(all[0].items.map(\.title) == ["Password Manager", "Worktrees", "Files"])
        #expect(all[1].items.map(\.title) == ["Kubernetes", "Notes"])
        guard case let .installed(_, fromRegistry) = all[1].items[0] else {
            Issue.record("Kubernetes isn't installed")
            return
        }
        #expect(fromRegistry?.id == "kubernetes", "an installed palette knows its repository entry")
        #expect(all[2].items.map(\.title) == ["Docker"], "installed palettes aren't offered again")
        #expect(all[2].items.first?.authors == ["thdxg"])

        let found = PaletteGalleryItem.sections(
            builtIn: PaletteScopeID.builtIn,
            installed: store.entries,
            registry: registry,
            query: "cont"
        )
        #expect(found.map(\.items.count) == [0, 0, 1])
        #expect(found[2].items.first?.title == "Docker")
    }
}
