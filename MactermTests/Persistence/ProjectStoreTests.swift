import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectStoreTests {
    private func makeStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
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
}
