import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectStoreTests {
    private func makeStore(fileURL: URL? = nil) -> ProjectStore {
        ProjectStore(fileURL: fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-tests-\(UUID().uuidString).json"))
    }

    @Test
    func find_or_create_reuses_canonical_local_path() {
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let existing = Project(name: "existing", path: base + "/./", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(name: "duplicate", path: base)

        #expect(project.id == existing.id)
        #expect(project.name == "existing")
        #expect(store.projects.count == 1)
    }

    @Test
    func create_always_appends_even_for_a_matching_path() {
        // Removing the one-project-per-directory constraint: `create` never
        // dedups, so the same directory can back several independent projects.
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let first = store.create(name: "one", path: base)
        let second = store.create(name: "two", path: base + "/./")

        #expect(first.id != second.id)
        #expect(store.projects.count == 2)
        // Both normalize to the same canonical path — distinct projects, one dir.
        #expect(store.projects.map(\.path) == [first.path, first.path])
        #expect(store.projects.map(\.name) == ["one", "two"])
    }

    @Test
    func find_or_create_reuses_matching_remote_path() {
        let store = makeStore()
        let existing = Project(name: "api", path: "devbox:~/dev/api", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(
            name: "duplicate",
            path: "devbox:~/dev/api",
            zmxPath: "~/bin/zmx"
        )

        #expect(project.id == existing.id)
        #expect(project.zmxPath == nil)
        #expect(store.projects.count == 1)
    }

    // MARK: - Mutators

    @Test
    func remove_drops_the_project() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        store.add(a)
        store.add(b)
        store.remove(id: a.id)
        #expect(store.projects.map(\.id) == [b.id])
    }

    @Test
    func rename_changes_name_but_not_identity_or_path() {
        let store = makeStore()
        let p = Project(name: "old", path: "/tmp/x", sortOrder: 0)
        store.add(p)
        store.rename(id: p.id, to: "new")
        let updated = store.projects.first { $0.id == p.id }
        #expect(updated?.name == "new")
        #expect(updated?.path == "/tmp/x")
    }

    @Test
    func setPath_updates_the_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func reorder_reindexes_sortOrder() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        let c = Project(name: "c", path: "/tmp/c", sortOrder: 2)
        store.add(a)
        store.add(b)
        store.add(c)
        // Move the last (c) to the front.
        store.reorder(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.projects.map(\.name) == ["c", "a", "b"])
        #expect(store.projects.map(\.sortOrder) == [0, 1, 2])
    }

    // MARK: - Path normalization (a stored trailing slash reaches $PWD verbatim: fatal under nushell — the pane fails to spawn — and blanks zsh's `%c` prompt)

    @Test
    func add_strips_trailing_slash_from_local_path() {
        let store = makeStore()
        store.add(Project(name: "junk", path: "/tmp/junk/", sortOrder: 0))
        #expect(store.projects.first?.path == "/tmp/junk")
    }

    @Test
    func add_leaves_remote_path_verbatim() {
        let store = makeStore()
        store.add(Project(name: "api", path: "devbox:~/dev/api/", sortOrder: 0))
        #expect(store.projects.first?.path == "devbox:~/dev/api/")
    }

    @Test
    func setPath_normalizes_the_new_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after/")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func load_migrates_paths_stored_with_trailing_slashes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-migrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // Write the legacy on-disk form directly — the store's own mutators
        // normalize now, so a pre-fix file has to be crafted by hand.
        let legacy = Project(name: "legacy", path: "/tmp/legacy/", sortOrder: 0)
        try JSONEncoder().encode([legacy]).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.first?.path == "/tmp/legacy")
    }

    // MARK: - On-disk round-trip

    @Test
    func round_trips_through_the_file() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = makeStore(fileURL: fileURL)
        let a = Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0)
        let b = Project(name: "beta", path: "/tmp/beta", sortOrder: 1)
        writer.add(a)
        writer.add(b)

        // A fresh store reading the same file sees the persisted contents.
        let reader = makeStore(fileURL: fileURL)
        #expect(reader.projects.map(\.name) == ["alpha", "beta"])
        #expect(reader.projects.map(\.path) == ["/tmp/alpha", "/tmp/beta"])
        #expect(reader.projects.map(\.id) == [a.id, b.id])
    }

    // MARK: - Corrupt-file save refusal (data-loss regression, #4.6)

    @Test
    func save_refuses_after_corrupt_load_so_a_mutation_cannot_clobber() throws {
        // A present-but-undecodable projects.json must NOT be overwritten by the
        // first subsequent mutation — that would wipe the user's project list.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let garbage = Data("{ not valid json".utf8)
        try garbage.write(to: fileURL)

        // init loads (and latches the failure); a mutation then triggers save().
        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.isEmpty)
        store.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0))

        // The corrupt file is preserved, not clobbered with the empty/new state.
        #expect(try Data(contentsOf: fileURL) == garbage)
    }
}
