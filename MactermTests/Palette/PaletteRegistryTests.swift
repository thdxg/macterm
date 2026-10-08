import Foundation
@testable import Macterm
import Testing

/// The palettes anyone can install (`PaletteRegistry`) and Settings →
/// Palettes' cards over them (`PaletteGalleryItem`), with GitHub served from
/// memory.
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

    /// GitHub's contents listing for `palettes/`, as the API returns it.
    private static func listing(_ names: [String], ref: String) -> Data {
        let items = names.map { name in
            [
                "name": name,
                "type": name.hasSuffix("/") ? "dir" : "file",
                "download_url": "https://raw.githubusercontent.com/thdxg/macterm/\(ref)/palettes/\(name)",
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? Data()
    }

    /// A fetch answering from `files` by URL, counting the listing reads.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: (Data, Int)] = [:]
        private var listings = 0
        var listingReads: Int { lock.withLock { listings } }

        var fetch: PaletteRegistry.Fetch {
            { [self] url in
                lock.withLock {
                    if url.host == "api.github.com" { listings += 1 }
                    return responses[url.absoluteString] ?? (Data(), 404)
                }
            }
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

    @Test
    func a_build_reads_the_palettes_of_its_own_version() {
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm.debug", version: "0.0.0") == "main")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.31.2-tip.44") == "tip")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.32.0-beta.4") == "v1.32.0-beta.4")
        #expect(PaletteRegistry.ref(bundleID: "com.thdxg.macterm", version: "1.32.0") == "v1.32.0")
        #expect(PaletteRegistry.listingURL(ref: "v1.32.0").absoluteString
            == "https://api.github.com/repos/thdxg/macterm/contents/palettes?ref=v1.32.0")
    }

    @Test
    func a_listing_yields_its_yaml_files_by_id() throws {
        let files = try PaletteRegistry.parseListing(Self.listing(["kubernetes.yaml", "README.md", "git.yaml", "old.yml"], ref: "main"))
        #expect(files.map(\.id) == ["git", "kubernetes"], "palettes are .yaml; the README isn't one")
        #expect(files.first?.url.absoluteString == "https://raw.githubusercontent.com/thdxg/macterm/main/palettes/git.yaml")
    }

    @Test
    func a_refresh_reads_every_palette_through_this_builds_validator_once_an_hour() async {
        let server = Server()
        let ref = "v1.32.0"
        server.responses[PaletteRegistry.listingURL(ref: ref).absoluteString] = (
            Self.listing(["kubernetes.yaml", "future.yaml"], ref: ref),
            200
        )
        server.responses["https://raw.githubusercontent.com/thdxg/macterm/\(ref)/palettes/kubernetes.yaml"] = (
            Data(Self.kubernetes.utf8),
            200
        )
        server.responses["https://raw.githubusercontent.com/thdxg/macterm/\(ref)/palettes/future.yaml"] = (
            Data(Self.fromTheFuture.utf8),
            200
        )
        let registry = PaletteRegistry(ref: ref, fetch: server.fetch)

        registry.refresh()
        #expect(registry.state == .loading)
        await settle()
        guard case .loaded = registry.state else {
            Issue.record("not loaded: \(registry.state)")
            return
        }
        #expect(registry.entries.map(\.id) == ["future", "kubernetes"])
        #expect(registry.entries.last?.name == "Kubernetes")
        #expect(registry.entries.last?.description == "Browse clusters")
        #expect(registry.entries.first?.failure?.errorDescription == "someNewKey: no such key", "a newer palette says why it can't be read")

        registry.refresh()
        await settle()
        #expect(server.listingReads == 1, "read once an hour")
        registry.refresh(force: true)
        await settle()
        #expect(server.listingReads == 2, "Refresh reads again")
    }

    @Test
    func a_version_without_palettes_says_so() async {
        let registry = PaletteRegistry(ref: "v1.0.0", fetch: Server().fetch)
        registry.refresh()
        await settle()
        #expect(registry.state == .failed("No palettes for this version (v1.0.0)."))
        #expect(registry.entries.isEmpty)
    }

    @Test
    func installing_copies_the_file_in_and_never_overwrites() throws {
        let store = try makeStore()
        let registry = PaletteRegistry(ref: "main", fetch: Server().fetch)
        let entry = PaletteRegistry.Entry(id: "kubernetes", text: Self.kubernetes)

        let url = try registry.install(entry, into: store)
        #expect(url.lastPathComponent == "kubernetes.yaml")
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.kubernetes, "the file as it is in the repository")
        #expect(store.palette(id: "kubernetes")?.name == "Kubernetes", "installed at once")

        #expect(throws: PaletteRegistry.InstallError.alreadyInstalled("kubernetes.yaml")) {
            try registry.install(entry, into: store)
        }
        try "name: Mine\nnodes: { root: { items: [] } }".write(
            to: store.directoryURL.appendingPathComponent("git.yml"), atomically: true, encoding: .utf8
        )
        #expect(throws: PaletteRegistry.InstallError.alreadyInstalled("git.yml"), "a .yml of the same name is the user's too") {
            try registry.install(PaletteRegistry.Entry(id: "git", text: Self.kubernetes), into: store)
        }
        #expect(throws: PaletteRegistry.InstallError.self, "a palette this build can't read isn't installed") {
            try registry.install(PaletteRegistry.Entry(id: "future", text: Self.fromTheFuture), into: store)
        }
        #expect(!FileManager.default.fileExists(atPath: store.directoryURL.appendingPathComponent("future.yaml").path))
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
            PaletteRegistry.Entry(id: "kubernetes", text: Self.kubernetes),
            PaletteRegistry.Entry(
                id: "docker",
                text: "name: Docker\ndescription: Containers\nnodes: { root: { list: ls, action: { copy: . } } }"
            ),
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
