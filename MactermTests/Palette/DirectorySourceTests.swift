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
    func bare_home_spec_names_the_project_after_the_host() throws {
        let (ctx, _, _) = makeContext()
        let item = try #require(DirectorySource().items(query: "devbox:~", context: ctx).first)
        #expect(item.title == "devbox")
    }
}
