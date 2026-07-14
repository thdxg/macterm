import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectSourceTests {
    // MARK: - Helpers

    /// A PaletteContext backed entirely by tempdirs (never the developer's real
    /// projects.json or ~/.config/macterm/projects/), with `projects` seeded.
    private func makeContext(_ projects: [Project]) -> (PaletteContext, AppState, ProjectStore) {
        let wsTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-ps-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-ps-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-ps-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: wsTmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        for project in projects {
            store.add(project)
        }
        return (PaletteContext(appState: state, projectStore: store), state, store)
    }

    // MARK: - items(query:)

    @Test
    func items_match_by_name() {
        let (ctx, _, _) = makeContext([Project(name: "widgets", path: "/tmp/widgets")])
        let results = ProjectSource().items(query: "widg", context: ctx)
        #expect(results.count == 1)
        #expect(results.first?.title == "widgets")
    }

    @Test
    func items_match_by_path() {
        let (ctx, _, _) = makeContext([Project(name: "alpha", path: "/tmp/beta-dir")])
        // The needle matches the path but not the name.
        let results = ProjectSource().items(query: "beta", context: ctx)
        #expect(results.count == 1)
        #expect(results.first?.title == "alpha")
    }

    @Test
    func items_use_best_of_name_or_path_score() throws {
        // Name is an exact prefix (score 0 before boost); path is a worse match.
        // The best-of should win, and the projectBoost (-1) applies.
        let (ctx, _, _) = makeContext([Project(name: "server", path: "/tmp/xyz/server")])
        let item = try #require(ProjectSource().items(query: "server", context: ctx).first)
        // Prefix name match (0) + projectBoost (-1) = -1.
        #expect(item.score == -1)
    }

    @Test
    func items_omit_nonmatching_projects() {
        let (ctx, _, _) = makeContext([Project(name: "alpha", path: "/tmp/alpha")])
        #expect(ProjectSource().items(query: "zzznope", context: ctx).isEmpty)
    }

    @Test
    func items_boost_ranks_project_below_command_only_when_worse() throws {
        // The boost is -1: a project match ranks just above an equal raw score.
        let (ctx, _, _) = makeContext([Project(name: "status", path: "/tmp/status")])
        let item = try #require(ProjectSource().items(query: "status", context: ctx).first)
        #expect(item.score < 0) // boosted below a bare command's typical positive score
    }

    // MARK: - emptyItems

    @Test
    func emptyItems_excludes_the_active_project() {
        let active = Project(name: "active", path: "/tmp/active")
        let other = Project(name: "other", path: "/tmp/other")
        let (ctx, state, _) = makeContext([active, other])
        state.selectProject(active)
        let titles = ProjectSource().emptyItems(context: ctx)?.map(\.title) ?? []
        #expect(!titles.contains("active"))
        #expect(titles.contains("other"))
    }

    @Test
    func emptyItems_caps_at_five() {
        let projects = (0 ..< 8).map { Project(name: "p\($0)", path: "/tmp/p\($0)") }
        let (ctx, _, _) = makeContext(projects)
        let items = ProjectSource().emptyItems(context: ctx) ?? []
        #expect(items.count == 5)
    }

    @Test
    func emptyItems_nil_when_only_the_active_project_exists() {
        let only = Project(name: "solo", path: "/tmp/solo")
        let (ctx, state, _) = makeContext([only])
        state.selectProject(only)
        #expect(ProjectSource().emptyItems(context: ctx) == nil)
    }

    @Test
    func emptyItems_falls_back_to_store_when_recency_is_empty() {
        // No project selected → recency is empty → falls back to the store list.
        let (ctx, _, _) = makeContext([
            Project(name: "one", path: "/tmp/one"),
            Project(name: "two", path: "/tmp/two"),
        ])
        let titles = ProjectSource().emptyItems(context: ctx)?.map(\.title) ?? []
        #expect(Set(titles) == ["one", "two"])
    }
}
