import AppKit
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
    private static func tree(_ files: [(path: String, mode: String)], shas: [String: String] = [:]) -> Data {
        var items: [[String: Any]] = []
        var folders = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/")
            if parts.count > 1, folders.insert(String(parts[0])).inserted {
                items.append(["path": String(parts[0]), "mode": "040000", "type": "tree", "sha": "0"])
            }
            items.append(["path": file.path, "mode": file.mode, "type": "blob", "sha": shas[file.path] ?? "0", "size": 10])
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
        return CustomPaletteStore(configDirectoryURL: dir)
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
        let allTexts = texts.merging(extraTexts) { _, new in new }
        // Each text file has its real Git blob SHA, as the tree reports it.
        let withSHAs = (files + extra).map { file in
            PaletteRegistry.File(
                path: file.path, size: file.size, executable: file.executable,
                sha: allTexts[file.path].map { ExtensionSource.blobSHA(Data($0.utf8)) } ?? file.sha
            )
        }
        return PaletteRegistry.Entry(id: id, files: withSHAs, texts: allTexts)
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
        #expect(Self.entry("nameless", manifest: "description: Y\n").failure != nil)
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
        #expect(installed?.features == ["Contexts palette", "Pods palette"], "each palette is a feature of the extension")
        #expect(installed?.uninstallMessage == "Contexts palette and Pods palette will be deleted.", "the prompt names each feature")
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
    func palettes_come_only_from_extensions() throws {
        let store = try makeStore()
        let config = store.extensionsURL.deletingLastPathComponent()
        let folder = store.extensionsURL.appendingPathComponent("git", isDirectory: true)
        let oldFolder = config.appendingPathComponent("palettes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("palettes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try "name: Git\ndescription: Branches\n".write(
            to: folder.appendingPathComponent("extension.yaml"),
            atomically: true,
            encoding: .utf8
        )
        try Self.pods.write(to: folder.appendingPathComponent("palettes/git.yaml"), atomically: true, encoding: .utf8)
        try Self.pods.write(to: oldFolder.appendingPathComponent("notes.yaml"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.entries.map(\.id) == ["git/git"], "a file in the old palettes folder is not read")
        #expect(store.installedExtension(id: "git")?.problem == nil, "an extension of your own needs no authors")
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
        #expect(try ExtensionManifest.parse(yaml: "name: K\ndescription: D").authors.isEmpty, "authors are optional")
        for bad in [
            "description: D\nauthors: [a]",
            "name: K\nauthors: [a]",
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
    /// one listed once, the built-in screens not at all —
    /// ranked by the search when there is one.
    @Test
    func the_gallery_is_one_list_of_extensions_installed_or_not() async throws {
        let store = try makeStore()
        let registry = [
            Self.entry("kubernetes"),
            Self.entry("docker", manifest: "name: Docker\ndescription: Containers\nauthors: [thdxg]\n"),
        ]
        _ = try await PaletteRegistry(ref: "main", fetch: Server().fetch).install(registry[0], into: store)

        let all = ExtensionGalleryItem.items(installed: store.extensions, registry: registry, query: "")
        #expect(all.map(\.title) == ["Kubernetes", "Docker"], "Kubernetes once, no built-ins")
        #expect(all.map(\.isInstalled) == [true, false])
        guard case let .installed(_, fromRegistry) = all[0] else {
            Issue.record("Kubernetes isn't installed")
            return
        }
        #expect(fromRegistry?.id == "kubernetes", "an installed extension knows its repository entry")
        #expect(all[0].summary == "Browse a cluster", "the extension's own description, not a palette's")

        let found = ExtensionGalleryItem.items(installed: store.extensions, registry: registry, query: "cont")
        #expect(found.map(\.title) == ["Docker"])

        let zebra = Self.entry("zebra", manifest: "name: Abacus\ndescription: Count\nauthors: [thdxg]\n")
        let withAbacus = registry + [zebra]
        #expect(
            ExtensionGalleryItem.items(installed: store.extensions, registry: withAbacus, query: "").map(\.title)
                == ["Kubernetes", "Abacus", "Docker"],
            "installed first, then the rest, each by name"
        )
        #expect(ExtensionGalleryItem.items(installed: store.extensions, registry: withAbacus, query: "", filter: .installed).map(\.title)
            == ["Kubernetes"])
        #expect(ExtensionGalleryItem.items(installed: store.extensions, registry: withAbacus, query: "", filter: .notInstalled).map(\.title)
            == ["Abacus", "Docker"])
    }

    @Test
    func uninstalling_moves_the_extension_to_the_trash() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let folder = try await registry.install(Self.entry("kubernetes"), into: store)

        #expect(store.installedExtension(id: "kubernetes")?.uninstallMessage == "Pods palette will be deleted.")
        let deletes = CustomPaletteStore.InstalledExtension.deletionMessage
        #expect(deletes(["A palette", "B palette", "C palette"]) == "A palette, B palette, and 1 more feature will be deleted.")
        #expect(deletes(["A", "B", "C", "D"]) == "A, B, and 2 more features will be deleted.")
        try store.uninstall(extensionID: "kubernetes")
        #expect(store.installedExtension(id: "kubernetes") == nil)
        #expect(store.entry(id: "kubernetes/pods") == nil, "its palettes go with it")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the whole folder")
    }

    /// A blank PNG of `side` × `side` pixels.
    static func png(side: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test
    func an_icon_is_a_symbol_or_a_png_of_one_size_in_the_extension_folder() throws {
        let icon = Self.png(side: MactermExtension.iconPixelSize)
        let files = ["icon.png": icon, "small.png": Self.png(side: 64), "fake.png": Data("not a png".utf8)]
        let resolve = { (name: String?) in
            MactermExtension.icon(of: ExtensionManifest(name: "X", description: "Y", icon: name)) { files[$0] }
        }
        #expect(resolve(nil) == (.symbol(MactermExtension.defaultIcon), nil))
        #expect(resolve("cube.box") == (.symbol("cube.box"), nil), "a symbol name, dots and all")
        #expect(resolve("icon.png") == (.image(icon), nil))
        #expect(resolve("small.png") == (.symbol(MactermExtension.defaultIcon), "icon: small.png is not a PNG of 128×128 pixels"))
        #expect(resolve("fake.png").problem == "icon: fake.png is not a PNG of 128×128 pixels")
        #expect(resolve("gone.png") == (.symbol(MactermExtension.defaultIcon), "icon: no file gone.png"))

        let parse = { (icon: String) in try ExtensionManifest.parse(yaml: "name: X\ndescription: Y\nicon: \(icon)\n") }
        #expect(try parse("assets/icon.png").icon == "assets/icon.png")
        for outside in ["../icon.png", "/tmp/icon.png", "assets//icon.png", "./icon.png"] {
            #expect(throws: CustomPaletteError.invalid("extension.yaml: icon: \(outside) is not a path inside the extension folder")) {
                try parse(outside)
            }
        }
    }

    @Test
    func an_icon_file_shows_on_the_card_before_install_and_on_every_palette_after() async throws {
        let icon = Self.png(side: MactermExtension.iconPixelSize)
        let manifest = "name: Kubernetes\ndescription: Browse a cluster\nicon: icon.png\nauthors: [thdxg]\n"
        let server = Server()
        server.responses[PaletteRegistry.treeURL(ref: "main").absoluteString] = (Self.tree([
            ("kubernetes/README.md", "100644"),
            ("kubernetes/extension.yaml", "100644"),
            ("kubernetes/icon.png", "100644"),
            ("kubernetes/palettes/pods.yaml", "100644"),
            ("missing/README.md", "100644"),
            ("missing/extension.yaml", "100644"),
            ("missing/palettes/pods.yaml", "100644"),
        ]), 200)
        for id in ["kubernetes", "missing"] {
            server.serve(ref: "main", id: id, "README.md", Self.readme)
            server.serve(ref: "main", id: id, "extension.yaml", manifest)
            server.serve(ref: "main", id: id, "palettes/pods.yaml", Self.pods)
        }
        server.serve(ref: "main", id: "kubernetes", "icon.png", icon)
        let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
        registry.refresh()
        await settle()
        let kubernetes = try #require(registry.entries.first { $0.id == "kubernetes" })
        #expect(kubernetes.icon == .image(icon), "read with the text, so the card shows it")
        #expect(kubernetes.failure == nil)
        let missing = try #require(registry.entries.first { $0.id == "missing" })
        #expect(missing.failure?.errorDescription == "extension.yaml: icon: no file icon.png", "it can't be installed")

        let store = try makeStore()
        server.responses.removeAll()
        let folder = try await registry.install(kubernetes, into: store)
        #expect(try Data(contentsOf: folder.appendingPathComponent("icon.png")) == icon, "installed from what the card showed")
        #expect(store.installedExtension(id: "kubernetes")?.icon == .image(icon))
        #expect(store.entry(id: "kubernetes/pods")?.pill.icon == .image(icon), "its palettes show it")

        // A new icon file is seen on the next open of the palette, as a
        // palette edit is. One of the wrong size gives the default and says why.
        try Self.png(side: 64).write(to: folder.appendingPathComponent("icon.png"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: folder.appendingPathComponent("icon.png").path
        )
        store.reloadIfChanged()
        #expect(store.entry(id: "kubernetes/pods")?.pill.icon == .symbol(MactermExtension.defaultIcon))
        #expect(store.installedExtension(id: "kubernetes")?.problem == "extension.yaml: icon: icon.png is not a PNG of 128×128 pixels")
    }

    @Test
    func a_blob_sha_is_the_one_git_reports_and_hidden_files_are_not_part_of_an_extension() throws {
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(ExtensionSource.blobSHA(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("palettes"), withIntermediateDirectories: true)
        try "hello\n".write(to: folder.appendingPathComponent("palettes/a.yaml"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appendingPathComponent(MactermExtension.sourceName), atomically: true, encoding: .utf8)
        #expect(ExtensionSource.files(in: folder) == ["palettes/a.yaml": "ce013625030ba8dba906f756967f9e9ca394464a"])
    }

    @Test
    func install_records_the_source_and_an_edit_marks_the_copy_as_changed() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let entry = Self.entry("kubernetes")
        let folder = try await registry.install(entry, into: store)

        let installed = try #require(store.installedExtension(id: "kubernetes"))
        #expect(installed.source == ExtensionSource(repository: "thdxg/macterm", ref: "main", files: entry.shas))
        #expect(installed.files == entry.shas, "what Install wrote is what the tree reported")
        #expect(!installed.isModified)
        #expect(ExtensionGalleryItem.installed(installed, registry: entry).update == nil, "the same as the repository")

        // An edit to any file, not only a palette, is seen on the next reload.
        try "# Mine\n\nMy notes.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: folder.appendingPathComponent("README.md").path
        )
        store.reloadIfChanged()
        #expect(store.installedExtension(id: "kubernetes")?.isModified == true)
    }

    @Test
    func the_card_offers_an_update_only_where_the_repository_changed_and_asks_before_it_replaces_changes() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let original = Self.entry("kubernetes")
        let folder = try await registry.install(original, into: store)
        let newer = Self.entry("kubernetes", palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts])
        let card = { (entry: PaletteRegistry.Entry) in
            try ExtensionGalleryItem.installed(#require(store.installedExtension(id: "kubernetes")), registry: entry).update
        }

        #expect(try card(newer) == .available(newer), "an untouched copy updates at once")

        let readme = folder.appendingPathComponent("README.md")
        try "# Mine\n\nMy notes.\n".write(to: readme, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: readme.path)
        store.reloadIfChanged()
        #expect(try card(original) == nil, "a changed copy is the user's while the repository keeps its version")
        #expect(try card(newer) == .replacesChanges(newer), "an update replaces the changes, so it asks")

        // A copy with no record (installed before records, or by hand) can't
        // say whether it was changed, so an update asks too.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(MactermExtension.sourceName))
        store.reload()
        #expect(try card(newer) == .replacesChanges(newer))
        #expect(ExtensionGalleryItem.available(newer).update == nil, "not installed: Install, not Update")
    }

    @Test
    func update_replaces_the_copy_and_moves_the_old_one_to_the_trash() async throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let folder = try await registry.install(Self.entry("kubernetes"), into: store)
        try "mine".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        store.reload()
        let newer = Self.entry("kubernetes", palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts])

        try await registry.update(newer, into: store)
        let installed = try #require(store.installedExtension(id: "kubernetes"))
        #expect(installed.paletteIDs == ["kubernetes/contexts", "kubernetes/pods"], "the new version, at once")
        #expect(installed.source?.files == newer.shas)
        #expect(!installed.isModified)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path), "the old copy is in the Trash")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.extensionsURL.path)
        #expect(leftovers == ["kubernetes"], "nothing staged is left behind")

        await #expect(throws: PaletteRegistry.InstallError.notInstalled("docker")) {
            try await registry.update(Self.entry("docker"), into: store)
        }
    }

    @Test
    func a_copy_without_a_record_is_adopted_only_when_it_matches_the_repository() async throws {
        let store = try makeStore()
        let entry = Self.entry("kubernetes")
        let folder = try await PaletteRegistry(ref: "main", fetch: Server().fetch).install(entry, into: store)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(MactermExtension.sourceName))
        store.reload()

        // A registry whose tree reports `readme` as the README of the extension.
        let registry = { (readme: String) async -> PaletteRegistry in
            let server = Server()
            var texts = entry.texts
            texts["README.md"] = readme
            server.responses[PaletteRegistry.treeURL(ref: "main").absoluteString] = (Self.tree(
                texts.keys.map { ("kubernetes/\($0)", "100644") },
                shas: Dictionary(uniqueKeysWithValues: texts.map { ("kubernetes/\($0.key)", ExtensionSource.blobSHA(Data($0.value.utf8))) })
            ), 200)
            for (path, text) in texts {
                server.serve(ref: "main", id: "kubernetes", path, text)
            }
            let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
            registry.refresh()
            await self.settle()
            return registry
        }

        await registry("# Kubernetes\n\nSomething newer.\n").adoptUnrecordedInstalls(in: store)
        #expect(store.installedExtension(id: "kubernetes")?.source == nil, "a copy that differs may hold changes: no record")

        await registry(Self.readme).adoptUnrecordedInstalls(in: store)
        let adopted = try #require(store.installedExtension(id: "kubernetes"))
        #expect(adopted.source?.files == entry.shas, "the same files: it came from the repository")
        #expect(!adopted.isModified)
    }

    /// A server whose tree at `main` holds `entries`, each file with its
    /// real Git blob SHA, and serves their text.
    private static func serving(_ entries: [PaletteRegistry.Entry]) -> Server {
        let server = Server()
        var files: [(path: String, mode: String)] = []
        var shas: [String: String] = [:]
        for entry in entries {
            for (path, text) in entry.texts {
                files.append(("\(entry.id)/\(path)", "100644"))
                shas["\(entry.id)/\(path)"] = ExtensionSource.blobSHA(Data(text.utf8))
                server.serve(ref: "main", id: entry.id, path, text)
            }
        }
        server.responses[PaletteRegistry.treeURL(ref: "main").absoluteString] = (Self.tree(files, shas: shas), 200)
        return server
    }

    @Test
    func auto_update_takes_only_the_updates_that_need_no_question() async throws {
        let store = try makeStore()
        let installer = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let readme = "# Mine\n\nMy notes.\n"
        for id in ["untouched", "changed", "unrecorded", "current"] {
            try await installer.install(Self.entry(id), into: store)
        }
        let changed = store.extensionsURL.appendingPathComponent("changed/README.md")
        try readme.write(to: changed, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: store.extensionsURL.appendingPathComponent("unrecorded/\(MactermExtension.sourceName)"))
        store.reload()

        let newer = { (id: String) in Self.entry(id, palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts]) }
        let registry = [newer("untouched"), newer("changed"), newer("unrecorded"), Self.entry("current"), newer("other")]
        #expect(
            ExtensionAutoUpdater.pending(installed: store.extensions, registry: registry).map(\.id) == ["untouched"],
            "not a changed copy, not a copy with no record, not one that is current, not one that is not installed"
        )
        let future = Self.entry("untouched", palettes: ["pods.yaml": Self.pods, "future.yaml": Self.fromTheFuture])
        #expect(ExtensionAutoUpdater.pending(installed: store.extensions, registry: [future]).isEmpty, "not one that this build can't read")
    }

    @Test
    func auto_update_reads_nothing_while_off_and_announces_what_it_updated() async throws {
        let store = try makeStore()
        try await PaletteRegistry(ref: "main", fetch: Server().fetch).install(Self.entry("kubernetes"), into: store)
        try await PaletteRegistry(ref: "main", fetch: Server().fetch).install(Self.entry("docker"), into: store)
        let docker = store.extensionsURL.appendingPathComponent("docker/README.md")
        try "# Mine\n\nMy notes.\n".write(to: docker, atomically: true, encoding: .utf8)
        store.reload()

        let newer = { (id: String) in Self.entry(id, palettes: ["pods.yaml": Self.pods, "contexts.yaml": Self.contexts]) }
        let server = Self.serving([newer("kubernetes"), newer("docker")])
        let registry = PaletteRegistry(ref: "main", fetch: server.fetch)
        var enabled = false
        var announced: [[String]] = []
        let updater = ExtensionAutoUpdater(registry: registry, store: store, isEnabled: { enabled }, announce: { announced.append($0) })

        #expect(await updater.runOnce().isEmpty)
        #expect(server.treeReads == 0, "off: no read of the repository at all")

        enabled = true
        #expect(await updater.runOnce() == ["Kubernetes"])
        #expect(announced == [["Kubernetes"]])
        #expect(store.installedExtension(id: "kubernetes")?.paletteIDs == ["kubernetes/contexts", "kubernetes/pods"])
        #expect(try String(contentsOf: docker, encoding: .utf8) == "# Mine\n\nMy notes.\n", "a changed copy waits for a click")

        #expect(await updater.runOnce().isEmpty, "nothing left to update")
        #expect(announced.count == 1, "no toast for nothing")
    }
}
