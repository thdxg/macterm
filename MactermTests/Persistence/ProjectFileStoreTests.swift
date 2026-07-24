import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectFileStoreTests {
    /// Fresh store rooted in a unique tempdir; the directory is created lazily
    /// by the first write, mirroring production.
    private func makeStore() -> ProjectFileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-projectfiles-\(UUID().uuidString)", isDirectory: true)
        return ProjectFileStore(directoryURL: dir)
    }

    private func writeRaw(_ store: ProjectFileStore, filename: String, yaml: String) throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try yaml.write(to: store.directoryURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    private func filenames(_ store: ProjectFileStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)) ?? []).sorted()
    }

    // MARK: - Matching

    @Test
    func finds_file_by_canonical_path_not_filename() throws {
        let store = makeStore()
        try writeRaw(store, filename: "whatever.yaml", yaml: "path: /a/b/")
        let match = store.find(forProjectPath: "/a/b")
        #expect(match?.url.lastPathComponent == "whatever.yaml")
        #expect(store.find(forProjectPath: "/a/c") == nil)
    }

    @Test
    func missing_directory_scans_empty() {
        let store = makeStore()
        #expect(store.scan().isEmpty)
        #expect(store.find(forProjectPath: "/a") == nil)
    }

    @Test
    func duplicate_paths_first_filename_wins() throws {
        let store = makeStore()
        try writeRaw(store, filename: "b.yaml", yaml: "name: B\npath: /same")
        try writeRaw(store, filename: "a.yaml", yaml: "name: A\npath: /same")
        #expect(store.find(forProjectPath: "/same")?.url.lastPathComponent == "a.yaml")
    }

    @Test
    func yml_extension_is_scanned_too() throws {
        let store = makeStore()
        try writeRaw(store, filename: "p.yml", yaml: "path: /a")
        #expect(store.find(forProjectPath: "/a") != nil)
    }

    // MARK: - Apply state

    @Test
    func apply_state_none_without_matching_file() {
        #expect(makeStore().applyState(forProjectPath: "/a") == .none)
    }

    @Test
    func apply_state_applicable_with_tabs() throws {
        let store = makeStore()
        try writeRaw(store, filename: "p.yaml", yaml: """
        path: /a
        tabs:
          - run: btop
        """)
        #expect(store.applyState(forProjectPath: "/a") == .applicable)
    }

    @Test
    func apply_state_empty_tabs_for_bare_declaration() throws {
        let store = makeStore()
        try writeRaw(store, filename: "p.yaml", yaml: "path: /a")
        #expect(store.applyState(forProjectPath: "/a") == .emptyTabs)
        try writeRaw(store, filename: "p.yaml", yaml: "path: /a\ntabs: []")
        #expect(store.applyState(forProjectPath: "/a") == .emptyTabs)
    }

    @Test
    func apply_state_invalid_when_tabs_malformed() throws {
        let store = makeStore()
        try writeRaw(store, filename: "p.yaml", yaml: """
        path: /a
        tabs:
          - split: { direction: horizontal, first: { } }
        """)
        #expect(store.applyState(forProjectPath: "/a") == .invalid)
        #expect(throws: LayoutFileError.self) {
            try store.loadFull(forProjectPath: "/a")
        }
    }

    // MARK: - Write

    @Test
    func write_creates_slug_file() throws {
        let store = makeStore()
        try store.write(ProjectFile(name: "API Server", path: "/a"), projectName: "API Server")
        #expect(filenames(store) == ["api_server.yaml"])
        #expect(try store.loadFull(forProjectPath: "/a")?.name == "API Server")
    }

    @Test
    func write_collision_takes_numeric_suffix() throws {
        let store = makeStore()
        try writeRaw(store, filename: "repo.yaml", yaml: "path: /other")
        try store.write(ProjectFile(name: "repo", path: "/mine"), projectName: "repo")
        #expect(filenames(store) == ["repo.yaml", "repo_2.yaml"])
        #expect(store.find(forProjectPath: "/mine")?.url.lastPathComponent == "repo_2.yaml")
    }

    @Test
    func resave_overwrites_own_file_without_suffixing() throws {
        let store = makeStore()
        try store.write(ProjectFile(name: "api", path: "/a"), projectName: "api")
        try store.write(ProjectFile(name: "api", path: "/a", tabs: [
            LayoutTab(name: nil, layout: .pane(LayoutPane(cwd: nil, run: "btop", shell: nil))),
        ]), projectName: "api")
        #expect(filenames(store) == ["api.yaml"])
        #expect(store.applyState(forProjectPath: "/a") == .applicable)
    }

    @Test
    func resave_after_rename_realigns_filename() throws {
        let store = makeStore()
        try store.write(ProjectFile(name: "old name", path: "/a"), projectName: "old name")
        #expect(filenames(store) == ["old_name.yaml"])
        try store.write(ProjectFile(name: "new name", path: "/a"), projectName: "new name")
        #expect(filenames(store) == ["new_name.yaml"])
    }

    @Test
    func realign_never_steals_another_paths_slug() throws {
        let store = makeStore()
        try writeRaw(store, filename: "api.yaml", yaml: "path: /other")
        try store.write(ProjectFile(name: "api", path: "/mine"), projectName: "api")
        #expect(filenames(store) == ["api.yaml", "api_2.yaml"])
        // The other project's file is untouched.
        #expect(store.find(forProjectPath: "/other")?.url.lastPathComponent == "api.yaml")
    }

    @Test
    func write_rebinds_by_path_after_hand_rename() throws {
        let store = makeStore()
        try store.write(ProjectFile(name: "api", path: "/a"), projectName: "api")
        // User hand-renames the file; the next save still finds it by path
        // and realigns the name instead of leaving a duplicate behind.
        let fm = FileManager.default
        try fm.moveItem(
            at: store.directoryURL.appendingPathComponent("api.yaml"),
            to: store.directoryURL.appendingPathComponent("zzz.yaml")
        )
        try store.write(ProjectFile(name: "api", path: "/a"), projectName: "api")
        #expect(filenames(store) == ["api.yaml"])
    }

    @Test
    func write_contracts_home_prefix_to_tilde() throws {
        let store = makeStore()
        let home = ProjectPath.currentHome
        try store.write(ProjectFile(name: "api", path: "\(home)/dev/api"), projectName: "api")
        // The file is dotfile-syncable config: no hardcoded /Users/<name>.
        let text = try String(
            contentsOf: store.directoryURL.appendingPathComponent("api.yaml"),
            encoding: .utf8
        )
        #expect(!text.contains(home))
        let loaded = try store.loadFull(forProjectPath: "\(home)/dev/api")
        #expect(loaded?.path == "~/dev/api")
    }

    @Test
    func write_outside_home_stays_absolute() throws {
        let store = makeStore()
        try store.write(ProjectFile(name: "app", path: "/srv/app"), projectName: "app")
        #expect(try store.loadFull(forProjectPath: "/srv/app")?.path == "/srv/app")
    }

    @Test
    func write_returns_the_written_url() throws {
        let store = makeStore()
        let url = try store.write(ProjectFile(name: "api", path: "/a"), projectName: "api")
        #expect(url.lastPathComponent == "api.yaml")
    }

    @Test
    func matches_lists_duplicates_in_filename_order() throws {
        let store = makeStore()
        try writeRaw(store, filename: "b.yaml", yaml: "path: /same")
        try writeRaw(store, filename: "a.yaml", yaml: "path: /same")
        try writeRaw(store, filename: "other.yaml", yaml: "path: /other")
        #expect(store.matches(forProjectPath: "/same").map(\.url.lastPathComponent) == ["a.yaml", "b.yaml"])
    }

    @Test
    func unreadable_file_is_skipped_for_matching() throws {
        let store = makeStore()
        try writeRaw(store, filename: "broken.yaml", yaml: "path: [unclosed")
        try writeRaw(store, filename: "good.yaml", yaml: "path: /a")
        #expect(store.find(forProjectPath: "/a")?.url.lastPathComponent == "good.yaml")
        #expect(store.scan().count == 2)
    }

    // MARK: - Multiple projects per directory (per-project slug identity)

    @Test
    func owns_matches_slug_file_and_numeric_variants() {
        #expect(ProjectSlug.owns(filename: "api.yaml", slug: "api"))
        #expect(ProjectSlug.owns(filename: "API.YAML", slug: "api")) // extension + case ignored
        #expect(ProjectSlug.owns(filename: "api_2.yaml", slug: "api")) // collision variant
        #expect(!ProjectSlug.owns(filename: "api-staging.yaml", slug: "api")) // a different slug
        #expect(!ProjectSlug.owns(filename: "api_x.yaml", slug: "api")) // "_x" is not a numeric suffix
        #expect(!ProjectSlug.owns(filename: "web.yaml", slug: "api"))
    }

    @Test
    func find_prefers_the_projects_own_slug_among_same_path_files() throws {
        let store = makeStore()
        try writeRaw(store, filename: "api.yaml", yaml: "name: api\npath: /repo")
        try writeRaw(store, filename: "web.yaml", yaml: "name: web\npath: /repo")
        // Path alone is ambiguous; the slug picks each project's own file.
        #expect(store.find(forProjectPath: "/repo", preferredSlug: "api")?.url.lastPathComponent == "api.yaml")
        #expect(store.find(forProjectPath: "/repo", preferredSlug: "web")?.url.lastPathComponent == "web.yaml")
        // No preference (or one that matches nothing) falls back to filename order.
        #expect(store.find(forProjectPath: "/repo")?.url.lastPathComponent == "api.yaml")
        #expect(store.find(forProjectPath: "/repo", preferredSlug: "gone")?.url.lastPathComponent == "api.yaml")
    }

    @Test
    func write_leaves_a_siblings_same_path_file_untouched() throws {
        let store = makeStore()
        // "api" already backs /repo.
        try store.write(ProjectFile(name: "api", path: "/repo"), projectName: "api")
        // Saving sibling "web" (a distinct project on the same directory) adds
        // its own file rather than realign-deleting api's.
        try store.write(ProjectFile(name: "web", path: "/repo"), projectName: "web", reservedSlugs: ["api"])
        #expect(filenames(store) == ["api.yaml", "web.yaml"])
        #expect(try store.loadFull(forProjectPath: "/repo", preferredSlug: "api")?.name == "api")
        #expect(try store.loadFull(forProjectPath: "/repo", preferredSlug: "web")?.name == "web")
    }
}
