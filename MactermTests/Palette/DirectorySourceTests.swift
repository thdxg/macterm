import Foundation
@testable import Macterm
import Testing

@MainActor
struct DirectorySourceTests {
    private func makeContext() -> (PaletteContext, AppState, ProjectStore) {
        let stateTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: stateTmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        return (PaletteContext(appState: state, projectStore: store), state, store)
    }

    // MARK: - Remote-spec recognition (#104)

    @Test
    func remote_spec_recognition_requires_anchored_dir_and_clean_host() {
        // Path mode short-circuits the whole palette, so recognition must
        // not swallow command-ish queries containing a colon.
        #expect(PaletteQuery.isRemoteSpecQuery("devbox:~/dev/api"))
        #expect(PaletteQuery.isRemoteSpecQuery("me@10.0.0.5:/srv/app"))
        #expect(PaletteQuery.isRemoteSpecQuery("devbox:~"))
        #expect(!PaletteQuery.isRemoteSpecQuery("settings:on"))
        #expect(!PaletteQuery.isRemoteSpecQuery("devbox:work/api"))
        #expect(!PaletteQuery.isRemoteSpecQuery("some words:~/x"))
        #expect(!PaletteQuery.isRemoteSpecQuery("/local/path"))
        #expect(!PaletteQuery.isRemoteSpecQuery("devbox:"))
    }

    @Test
    func remote_spec_query_enters_path_mode() {
        #expect(PaletteQuery(raw: "devbox:~/dev").looksLikePath)
        #expect(!PaletteQuery(raw: "apply layout").looksLikePath)
    }

    // MARK: - Remote items

    @Test
    func local_directory_switches_to_existing_matching_project() throws {
        let (ctx, state, store) = makeContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-dir-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Project(name: "existing", path: dir.path + "/./", sortOrder: 0)
        store.add(existing)

        let items = DirectorySource().items(query: dir.path, context: ctx)
        let item = try #require(items.first)
        #expect(item.subtitle?.contains("Switch to project") == true)
        item.action()

        #expect(state.activeProjectID == existing.id)
        #expect(store.projects.count == 1)
    }

    @Test
    func local_directory_backing_a_project_also_offers_adding_another() throws {
        // A directory is not an identity — below "Switch to project" the
        // exact match offers creating a second, independent project there.
        let (ctx, state, store) = makeContext()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-dir-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Project(name: "existing", path: dir.path, sortOrder: 0)
        store.add(existing)

        let items = DirectorySource().items(query: dir.path, context: ctx)
        #expect(items.first?.subtitle?.contains("Switch to project") == true)
        let addAnother = try #require(items.first { $0.subtitle?.contains("Add another project") == true })
        // Ranked directly below the switch row, above any child listing.
        #expect(addAnother.score == 1)
        addAnother.action()

        #expect(store.projects.count == 2)
        let created = try #require(store.projects.last)
        #expect(created.id != existing.id)
        #expect(created.path == dir.path)
        #expect(state.activeProjectID == created.id)
    }

    @Test
    func children_backing_projects_also_offer_add_another_rows() throws {
        // A project-backed child completion pairs switch + add-another just
        // like the exact typed path — a partially-typed prefix must not
        // strand the user with switch-only (adding a second project would
        // otherwise require typing the full path). Unbacked children stay
        // single rows.
        let (ctx, _, store) = makeContext()
        let dir = try makeListingDir(children: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.add(Project(name: "alpha", path: dir.appendingPathComponent("alpha").path, sortOrder: 0))

        let items = DirectorySource().items(query: dir.path + "/", context: ctx)
        let switchIdx = try #require(items.firstIndex { $0.subtitle?.contains("Switch to project") == true })
        let addIdx = try #require(items.firstIndex { $0.subtitle?.contains("Add another project") == true })
        // The pair is adjacent, switch first; beta (unbacked) stays single.
        #expect(addIdx == switchIdx + 1)
        #expect(items.count(where: { $0.title == "beta" }) == 1)
        #expect(items.count(where: { $0.subtitle?.contains("Add another project") == true }) == 1)
    }

    @Test
    func partial_prefix_narrowing_to_a_backed_child_offers_both_actions() throws {
        // The reported case: `~/dev/ma` narrowing to a single project-backed
        // `macterm` child must offer add-another, not switch-only.
        let (ctx, _, store) = makeContext()
        let dir = try makeListingDir(children: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.add(Project(name: "alpha", path: dir.appendingPathComponent("alpha").path, sortOrder: 0))

        let items = DirectorySource().items(query: dir.path + "/al", context: ctx)
        #expect(items.contains { $0.subtitle?.contains("Switch to project") == true })
        #expect(items.contains { $0.subtitle?.contains("Add another project") == true })
    }

    @Test
    func typed_remote_spec_offers_add_as_remote_project() throws {
        let (ctx, state, store) = makeContext()
        let items = DirectorySource().items(query: "devbox:~/dev/api", context: ctx)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "api")
        #expect(item.subtitle?.contains("Add remote project") == true)

        item.action()
        let added = try #require(store.projects.first)
        #expect(added.path == "devbox:~/dev/api")
        #expect(added.isRemote)
        #expect(state.activeProjectID == added.id)
    }

    @Test
    func typed_remote_spec_switches_to_existing_matching_project() throws {
        let (ctx, state, store) = makeContext()
        let existing = Project(name: "api box", path: "devbox:~/dev/api", sortOrder: 0)
        store.add(existing)

        let items = DirectorySource().items(query: "devbox:~/dev/api", context: ctx)
        let item = try #require(items.first)
        #expect(item.subtitle?.contains("Switch to remote project") == true)
        item.action()
        #expect(state.activeProjectID == existing.id)
        #expect(store.projects.count == 1)
    }

    @Test
    func typed_remote_spec_backing_a_project_also_offers_adding_another() throws {
        let (ctx, state, store) = makeContext()
        let existing = Project(name: "api box", path: "devbox:~/dev/api", sortOrder: 0)
        store.add(existing)

        let items = DirectorySource().items(query: "devbox:~/dev/api", context: ctx)
        let addAnother = try #require(items.first { $0.subtitle?.contains("Add another project") == true })
        #expect(addAnother.title == "api")
        addAnother.action()

        #expect(store.projects.count == 2)
        let created = try #require(store.projects.last)
        #expect(created.id != existing.id)
        #expect(created.path == "devbox:~/dev/api")
        #expect(created.isRemote)
        #expect(state.activeProjectID == created.id)
    }

    @Test
    func bare_home_spec_names_the_project_after_the_host() throws {
        let (ctx, _, _) = makeContext()
        let item = try #require(DirectorySource().items(query: "devbox:~", context: ctx).first)
        #expect(item.title == "devbox")
    }

    // MARK: - Local directory listing

    /// Build a tempdir with the given child directories (and optional files).
    private func makeListingDir(children: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-listing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for child in children {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(child, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// The child rows a query returns. Excludes the exact-match rows that a
    /// trailing-slash directory query surfaces at the top for the directory
    /// itself — identified by the item id's path (ids embed the full path),
    /// not by score, which is a plain running counter.
    private func childTitles(_ query: String, in ctx: PaletteContext) -> [String] {
        let expanded = (query as NSString).expandingTildeInPath
        let exact = expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        return DirectorySource().items(query: query, context: ctx)
            .filter { !$0.id.hasSuffix(":\(exact)") }
            .map(\.title)
    }

    @Test
    func local_listing_completes_children_of_a_directory() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: ["alpha", "beta", "gamma"])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Trailing slash → dir itself is the browse target; all children match.
        let titles = childTitles(dir.path + "/", in: ctx)
        #expect(Set(titles) == ["alpha", "beta", "gamma"])
    }

    @Test
    func local_listing_filters_by_typed_prefix_case_insensitively() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: ["Alpha", "album", "beta"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let titles = childTitles(dir.path + "/al", in: ctx)
        #expect(Set(titles) == ["Alpha", "album"])
    }

    @Test
    func local_listing_hides_dotdirs_by_default() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: [".hidden", "visible"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let titles = childTitles(dir.path + "/", in: ctx)
        #expect(titles == ["visible"])
    }

    /// Regression for 6.4: a typed prefix that itself opts into the hidden
    /// namespace (`.co…`) must complete dotdirs.
    @Test
    func local_listing_reveals_dotdirs_when_prefix_starts_with_dot() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: [".config", ".cache", "visible"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let titles = childTitles(dir.path + "/.co", in: ctx)
        #expect(titles == [".config"])
    }

    @Test
    func local_listing_caps_at_ten_children() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: (0 ..< 20).map { String(format: "d%02d", $0) })
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(childTitles(dir.path + "/", in: ctx).count == 10)
    }

    /// Regression for 6.3: the listing is deterministic (sorted), so both which
    /// 10 survive the cap and their order are stable across runs.
    @Test
    func local_listing_is_deterministic_and_sorted() throws {
        let (ctx, _, _) = makeContext()
        let dir = try makeListingDir(children: (0 ..< 20).map { String(format: "d%02d", $0) })
        defer { try? FileManager.default.removeItem(at: dir) }
        let titles = childTitles(dir.path + "/", in: ctx)
        // Sorted ascending → the first ten are d00…d09, in order.
        #expect(titles == (0 ..< 10).map { String(format: "d%02d", $0) })
    }
}
