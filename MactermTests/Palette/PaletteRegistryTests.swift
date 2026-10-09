import Foundation
@testable import Macterm
import Testing

/// The extensions anyone can install (`PaletteRegistry`), the store reading
/// them once installed, and Settings → Extensions' cards over both
/// (`ExtensionGalleryItem`), with GitHub served from memory.
@MainActor
struct PaletteRegistryTests {
    private static let pods = """
    name: Pods
    description: Browse a cluster's pods
    icon: shippingbox
    requires: [kubectl]
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let contexts = """
    name: Contexts
    description: Switch the current context
    requires: [kubectl]
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let fromTheFuture = """
    name: Future
    someNewKey: true
    nodes: { root: { list: ls, action: { copy: . } } }

    """
    private static let manifest = "name: Kubernetes\ndescription: Browse a cluster\nicon: helm\nauthors: [thdxg]\n"
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

    /// An extension of `palettes` (file name → YAML) with a README and
    /// `manifest`.
    private static func entry(
        _ id: String,
        palettes: [String: String] = ["pods.yaml": pods],
        manifest: String = manifest,
        extra: [PaletteRegistry.File] = [],
        texts extraTexts: [String: String] = [:]
    ) -> PaletteRegistry.Entry {
        var files: [PaletteRegistry.File] = [
            .init(path: "README.md", size: 10, executable: false),
            .init(path: "extension.yaml", size: 10, executable: false),
        ]
        var texts = ["README.md": readme, "extension.yaml": manifest]
        for (name, yaml) in palettes.sorted(by: { $0.key < $1.key }) {
            files.append(.init(path: "palettes/\(name)", size: 10, executable: false))
            texts["palettes/\(name)"] = yaml
        }
        return PaletteRegistry.Entry(id: id, files: files + extra, texts: texts.merging(extraTexts) { _, new in new })
    }

    @Test
    func every_build_reads_the_extensions_on_main() {
        #expect(PaletteRegistry().ref == "main", "not tied to the app's version")
        #expect(PaletteRegistry.treeURL(ref: "main").absoluteString
            == "https://api.github.com/repos/thdxg/macterm/git/trees/main:extensions?recursive=1")
        #expect(PaletteRegistry.fileURL(ref: "main", id: "git", path: "palettes/git.yaml").absoluteString
            == "https://raw.githubusercontent.com/thdxg/macterm/main/extensions/git/palettes/git.yaml")
        #expect(PaletteRegistry.folderURL(ref: "main", id: "git").absoluteString
            == "https://github.com/thdxg/macterm/tree/main/extensions/git")
    }

    @Test
    func a_tree_yields_each_folder_with_a_manifest_and_its_files() throws {
        let extensions = try PaletteRegistry.parseTree(Self.tree([
            ("README.md", "100644"),
            ("kubernetes/extension.yaml", "100644"),
            ("kubernetes/palettes/pods.yaml", "100644"),
            ("kubernetes/scripts/pods.sh", "100755"),
            ("draft/palettes/notes.yaml", "100644"),
        ]))
        #expect(extensions.map(\.id) == ["kubernetes"], "the top README and a folder without extension.yaml are no extension")
        #expect(extensions.first?.files.map(\.path) == ["extension.yaml", "palettes/pods.yaml", "scripts/pods.sh"])
        #expect(extensions.first?.files.map(\.executable) == [false, false, true])
    }

    @Test
    func an_extension_has_its_own_name_and_any_number_of_palettes() {
        let entry = Self.entry("kubernetes", palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts])
        #expect(entry.name == "Kubernetes" && entry.description == "Browse a cluster" && entry.icon == "helm")
        #expect(entry.palettes.map(\.path) == ["palettes/contexts.yaml", "palettes/pods.yaml"])
        #expect(entry.palettes.compactMap { try? $0.result.get().name } == ["Contexts", "Pods"], "each palette its own name")
        #expect(entry.failure == nil)

        #expect(Self.entry("empty", palettes: [:]).failure != nil, "an extension does something")
        let broken = Self.entry("kubernetes", palettes: ["pods.yaml": Self.pods, "future.yaml": Self.fromTheFuture])
        #expect(
            broken.failure?.errorDescription?.hasPrefix("palettes/future.yaml: ") == true,
            "one palette that can't be read names itself"
        )
        #expect(Self.entry("nobody", manifest: "name: X\ndescription: Y\nauthors: []\n").failure != nil)
    }

    @Test
    func a_refresh_reads_every_extension_through_this_builds_validator_once_an_hour() async {
        let server = Server()
        let ref = "v1.32.0"
        server.responses[PaletteRegistry.treeURL(ref: ref).absoluteString] = (Self.tree([
            ("kubernetes/README.md", "100644"),
            ("kubernetes/extension.yaml", "100644"),
            ("kubernetes/palettes/pods.yaml", "100644"),
            ("kubernetes/palettes/contexts.yaml", "100644"),
            ("kubernetes/shot.png", "100644"),
            ("future/extension.yaml", "100644"),
            ("future/palettes/future.yaml", "100644"),
        ]), 200)
        server.serve(ref: ref, id: "kubernetes", "README.md", Self.readme)
        server.serve(ref: ref, id: "kubernetes", "extension.yaml", Self.manifest)
        server.serve(ref: ref, id: "kubernetes", "palettes/pods.yaml", Self.pods)
        server.serve(ref: ref, id: "kubernetes", "palettes/contexts.yaml", Self.contexts)
        server.serve(ref: ref, id: "future", "extension.yaml", Self.manifest)
        server.serve(ref: ref, id: "future", "palettes/future.yaml", Self.fromTheFuture)
        let registry = PaletteRegistry(ref: ref, fetch: server.fetch)

        registry.refresh()
        #expect(registry.state == .loading)
        await settle()
        guard case .loaded = registry.state else {
            Issue.record("not loaded: \(registry.state)")
            return
        }
        #expect(registry.entries.map(\.id) == ["future", "kubernetes"])
        let kubernetes = registry.entries[1]
        #expect(kubernetes.name == "Kubernetes")
        #expect(kubernetes.authors == ["thdxg"])
        #expect(kubernetes.palettes.count == 2)
        #expect(kubernetes.texts["shot.png"] == nil, "images wait for the install")
        #expect(kubernetes.failure == nil)
        #expect(
            registry.entries[0].failure?.errorDescription == "palettes/future.yaml: someNewKey: no such key",
            "a newer palette says why it can't be read"
        )

        registry.refresh()
        await settle()
        #expect(server.treeReads == 1, "read once an hour, however often the pane opens")
    }

    @Test
    func a_failed_read_says_why_and_is_tried_again() async {
        let server = Server()
        let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
        registry.refresh()
        await settle()
        #expect(registry.state == .failed("Macterm's repository has no extensions at main."))
        #expect(registry.entries.isEmpty)
        registry.refresh()
        await settle()
        #expect(server.treeReads == 2, "a failure isn't kept for the hour")
    }

    @Test
    func installing_copies_the_folder_in_and_its_palettes_join_the_store() async throws {
        let store = try makeStore()
        let server = Server()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        server.serve(ref: "main", id: "kubernetes", "shot.png", png)
        let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
        let entry = Self.entry(
            "kubernetes",
            palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts],
            extra: [
                .init(path: "scripts/pods.sh", size: 10, executable: true),
                .init(path: "shot.png", size: 4, executable: false),
            ],
            texts: ["scripts/pods.sh": "#!/bin/sh\nkubectl get pods\n"]
        )

        let folder = try await registry.install(entry, into: store)
        #expect(folder == store.extensionsURL.appendingPathComponent("kubernetes", isDirectory: true))
        #expect(try String(contentsOf: folder.appendingPathComponent("palettes/pods.yaml"), encoding: .utf8) == Self.pods)
        #expect(try Data(contentsOf: folder.appendingPathComponent("shot.png")) == png, "images are fetched at install")
        let mode = try FileManager.default
            .attributesOfItem(atPath: folder.appendingPathComponent("scripts/pods.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755, "a script stays executable")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.extensionsURL.path)
        #expect(leftovers == ["kubernetes"], "nothing staged is left behind")

        let installed = store.installedExtension(id: "kubernetes")
        #expect(installed?.name == "Kubernetes")
        #expect(installed?.authors == ["thdxg"])
        #expect(installed?.problem == nil)
        #expect(installed?.paletteIDs == ["kubernetes/contexts", "kubernetes/pods"], "every palette, under the extension's id")
        let pods = store.entry(id: "kubernetes/pods")
        #expect(pods?.palette?.name == "Pods", "installed at once")
        #expect(pods?.extensionID == "kubernetes")
        #expect(pods?.extensionDirectory?.standardizedFileURL == folder.standardizedFileURL, "its commands get MACTERM_EXTENSION_DIR")

        await #expect(throws: PaletteRegistry.InstallError.alreadyInstalled("kubernetes")) {
            try await registry.install(entry, into: store)
        }
        await #expect(throws: PaletteRegistry.InstallError.self, "an extension this build can't read isn't installed") {
            try await registry.install(Self.entry("future", palettes: ["future.yaml": Self.fromTheFuture]), into: store)
        }
        #expect(!FileManager.default.fileExists(atPath: store.extensionsURL.appendingPathComponent("future").path))
    }

    @Test
    func a_failed_download_installs_nothing() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let entry = Self.entry("kubernetes", extra: [.init(path: "shot.png", size: 4, executable: false)])
        await #expect(throws: PaletteRegistry.RegistryError.self) {
            try await registry.install(entry, into: store)
        }
        #expect(store.installedExtension(id: "kubernetes") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.extensionsURL.appendingPathComponent("kubernetes").path))
    }

    @Test
    func an_extensions_palettes_never_share_an_id_with_a_palette_file() throws {
        let store = try makeStore()
        let folder = store.extensionsURL.appendingPathComponent("git", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("palettes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Self.manifest.write(to: folder.appendingPathComponent("extension.yaml"), atomically: true, encoding: .utf8)
        try Self.pods.write(to: folder.appendingPathComponent("palettes/git.yaml"), atomically: true, encoding: .utf8)
        try Self.pods.write(to: store.directoryURL.appendingPathComponent("git.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.entry(id: "git")?.extensionID == nil, "the user's own file")
        #expect(store.entry(id: "git/git")?.extensionID == "git", "the extension's, beside it")
    }

    @Test
    func a_broken_installed_extension_says_what_is_wrong() throws {
        let store = try makeStore()
        let folder = store.extensionsURL.appendingPathComponent("odd", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("palettes"), withIntermediateDirectories: true)
        try "name: Odd\n".write(to: folder.appendingPathComponent("extension.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.installedExtension(id: "odd")?.problem != nil, "a manifest without its fields")

        try Self.manifest.write(to: folder.appendingPathComponent("extension.yaml"), atomically: true, encoding: .utf8)
        try Self.fromTheFuture.write(to: folder.appendingPathComponent("palettes/future.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.installedExtension(id: "odd")?.problem?.hasPrefix("palettes/future.yaml: ") == true)
        #expect(store.entry(id: "odd/future")?.failure != nil, "and the palette keeps its row with the error, like a file's")
    }

    @Test
    func a_manifest_names_the_extension_and_its_authors() throws {
        let manifest = try ExtensionManifest.parse(yaml: "name: K\ndescription: D\nauthors: [thdxg, some-one]")
        #expect(manifest.authors == ["thdxg", "some-one"] && manifest.icon == nil)
        for bad in [
            "description: D\nauthors: [a]",
            "name: K\nauthors: [a]",
            "name: K\ndescription: D\nauthors: []",
            "name: K\ndescription: D\nauthors: [-bad]",
            "name: K\ndescription: D\nauthors: [a]\nversion: 2",
        ] {
            #expect(throws: CustomPaletteError.self, "\(bad)") { try ExtensionManifest.parse(yaml: bad) }
        }
        #expect(MactermExtension.summary(readme: Self.readme) == "Browse a cluster's pods.")
        #expect(MactermExtension.isID("claude-code"))
        #expect(!MactermExtension.isID("Claude_Code"))
        #expect(MactermExtension.isPalette("palettes/pods.yaml") && MactermExtension.isPalette("palettes/pods.yml"))
        #expect(!MactermExtension.isPalette("palettes/old/pods.yaml") && !MactermExtension.isPalette("pods.yaml"))
        #expect(MactermExtension.paletteID(extensionID: "kubernetes", path: "palettes/pods.yaml") == "kubernetes/pods")
    }

    @Test
    func a_screenshot_frames_the_palette_the_same_way_and_stays_on_screen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let palette = CGRect(x: 614, y: 500, width: 500, height: 420)
        let rect = MactermExtension.screenshotRect(around: palette, in: screen)
        #expect(rect.size == MactermExtension.screenshotPointSize)
        #expect(rect.midX == palette.midX, "centred across")
        #expect(rect.maxY == palette.maxY + MactermExtension.screenshotTopMargin, "the same room above every time")

        let nearTheCorner = CGRect(x: 1200, y: 690, width: 500, height: 420)
        let moved = MactermExtension.screenshotRect(around: nearTheCorner, in: screen)
        #expect(moved.maxY == screen.maxY && moved.maxX == screen.maxX, "kept on the screen")
    }

    @Test
    func a_screenshot_is_a_png_of_the_size_in_the_folder() throws {
        var header: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
        header += Array("IHDR".utf8) + [0, 0, 0x06, 0x40, 0, 0, 0x03, 0xE8]
        let size = MactermExtension.pngSize(Data(header))
        #expect(size?.width == 1600 && size?.height == 1000)
        #expect(MactermExtension.pngSize(Data("not a png at all, not at all".utf8)) == nil)
        #expect(MactermExtension.isScreenshot("screenshots/pods.png"))
        #expect(!MactermExtension.isScreenshot("pods.png"), "only in the folder")
        #expect(!MactermExtension.isScreenshot("screenshots/pods.jpg"), "only PNG")
        #expect(!MactermExtension.isScreenshot("screenshots/old/pods.png"), "not nested")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(MactermExtension.nextScreenshotName(in: folder) == "screenshot-1.png")
        try Data().write(to: folder.appendingPathComponent("screenshot-1.png"))
        #expect(MactermExtension.nextScreenshotName(in: folder) == "screenshot-2.png")
    }

    /// One list of extensions by name — installed and not, an installed
    /// one listed once, palette files and the built-in screens not at all —
    /// ranked by the search when there is one.
    @Test
    func the_gallery_is_one_list_of_extensions_installed_or_not() async throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Self.pods.write(to: store.directoryURL.appendingPathComponent("notes.yaml"), atomically: true, encoding: .utf8)
        let registry = [
            Self.entry("kubernetes"),
            Self.entry("docker", manifest: "name: Docker\ndescription: Containers\nauthors: [thdxg]\n"),
        ]
        _ = try await PaletteRegistry(ref: "main", fetch: Server().fetch).install(registry[0], into: store)

        let all = ExtensionGalleryItem.items(installed: store.extensions, registry: registry, query: "")
        #expect(all.map(\.title) == ["Docker", "Kubernetes"], "by name, Kubernetes once, no palette files or built-ins")
        #expect(all.map(\.isInstalled) == [false, true])
        guard case let .installed(_, fromRegistry) = all[1] else {
            Issue.record("Kubernetes isn't installed")
            return
        }
        #expect(fromRegistry?.id == "kubernetes", "an installed extension knows its repository entry")
        #expect(all[1].summary == "Browse a cluster", "the extension's own description, not a palette's")

        let found = ExtensionGalleryItem.items(installed: store.extensions, registry: registry, query: "cont")
        #expect(found.map(\.title) == ["Docker"])
    }

    @Test
    func uninstalling_moves_the_extension_to_the_trash() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let folder = try await registry.install(Self.entry("kubernetes"), into: store)

        try store.uninstall(extensionID: "kubernetes")
        #expect(store.installedExtension(id: "kubernetes") == nil)
        #expect(store.entry(id: "kubernetes/pods") == nil, "its palettes go with it")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the whole folder")
    }
}
