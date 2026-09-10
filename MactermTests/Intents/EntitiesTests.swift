import AppIntents
import Foundation
@testable import Macterm
import Testing

/// The entity queries — what the Shortcuts pickers offer and how a typed name
/// resolves. Serialized for the same reason as `MactermIntentsTests`: the
/// queries reach the app through `MactermIntentHost.shared`.
@Suite(.serialized)
@MainActor
struct EntitiesTests {
    private func makeHost() -> (AppState, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-entity-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-entity-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let appState = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        let projectStore = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-entity-tests-store-\(UUID().uuidString).json"))
        MactermIntentHost.shared.attachForTesting(appState: appState, projectStore: projectStore)
        return (appState, projectStore)
    }

    private func seedProject(
        _ appState: AppState,
        _ projectStore: ProjectStore,
        name: String,
        path: String = "/tmp"
    ) -> Project {
        let project = Project(name: name, path: path, sortOrder: projectStore.projects.count)
        projectStore.add(project)
        appState.selectProject(project)
        return project
    }

    // MARK: - Projects

    @Test
    func the_project_picker_lists_every_project() async throws {
        let (appState, projectStore) = makeHost()
        _ = seedProject(appState, projectStore, name: "api")
        _ = seedProject(appState, projectStore, name: "web")

        let listed = try await MactermProjectQuery().allEntities()

        #expect(listed.map(\.name) == ["api", "web"])
    }

    @Test
    func a_typed_project_name_matches_case_insensitively() async throws {
        let (appState, projectStore) = makeHost()
        _ = seedProject(appState, projectStore, name: "API")
        _ = seedProject(appState, projectStore, name: "web")

        let matched = try await MactermProjectQuery().entities(matching: "ap")

        #expect(matched.map(\.name) == ["API"])
    }

    @Test
    func a_project_resolves_by_identifier_and_a_stale_one_does_not() async throws {
        let (appState, projectStore) = makeHost()
        let project = seedProject(appState, projectStore, name: "api")

        let found = try await MactermProjectQuery().entities(for: [project.id])
        let missing = try await MactermProjectQuery().entities(for: [UUID()])

        #expect(found.map(\.id) == [project.id])
        #expect(missing.isEmpty)
    }

    @Test
    func the_pinned_workspace_is_offered_once_it_exists_and_before_the_projects() async throws {
        let (appState, projectStore) = makeHost()
        _ = seedProject(appState, projectStore, name: "api")
        #expect(try await MactermProjectQuery().allEntities().map(\.id) == projectStore.projects.map(\.id))

        // Pinning is what brings the sentinel workspace into being; tab and
        // pane actions work there like anywhere else, so it has to be
        // addressable.
        let tab = try #require(appState.workspaces[projectStore.projects[0].id]?.tabs.first)
        appState.pinTab(tab.id, fromProject: projectStore.projects[0].id)

        let listed = try await MactermProjectQuery().allEntities()
        #expect(listed.first?.id == PinnedTabs.projectID)
    }

    // MARK: - Tabs

    @Test
    func the_tab_picker_spans_projects_and_names_each_tabs_project() async throws {
        let (appState, projectStore) = makeHost()
        let api = seedProject(appState, projectStore, name: "api")
        let web = seedProject(appState, projectStore, name: "web")

        let listed = try await MactermTabQuery().allEntities()

        // Ordered by project (sidebar order), then tab order — not
        // `AppState.workspaces` dictionary order, which would reshuffle the
        // picker between openings.
        #expect(listed.count == 2)
        #expect(listed.map(\.project) == ["api", "web"])
        #expect(appState.workspaces[api.id]?.tabs.count == 1)
        #expect(appState.workspaces[web.id]?.tabs.count == 1)
    }

    @Test
    func a_tab_resolves_across_projects_because_the_entity_carries_no_project() throws {
        let (appState, projectStore) = makeHost()
        _ = seedProject(appState, projectStore, name: "api")
        let web = seedProject(appState, projectStore, name: "web")
        let tab = try #require(appState.workspaces[web.id]?.tabs.first)

        let resolved = try IntentTargets.tab(tab.id, in: AppCommandContext(
            appState: appState,
            projectStore: projectStore
        ))

        #expect(resolved.projectID == web.id)
        #expect(resolved.tab === tab)
    }

    // MARK: - Panes

    @Test
    func the_pane_picker_lists_panes_in_a_stable_order() async throws {
        let (appState, projectStore) = makeHost()
        let api = seedProject(appState, projectStore, name: "api")
        _ = seedProject(appState, projectStore, name: "web")

        let listed = try await MactermPaneQuery().allEntities()

        #expect(listed.count == 2)
        #expect(listed.first?.project == "api")
        #expect(listed.first?.id == appState.workspaces[api.id]?.tabs.first?
            .splitRoot.allPanes().first?.sessionName)
    }

    @Test
    func a_pane_matches_on_its_session_name_as_well_as_its_title() async throws {
        let (appState, projectStore) = makeHost()
        let api = seedProject(appState, projectStore, name: "api")
        let pane = try #require(appState.workspaces[api.id]?.tabs.first?.splitRoot.allPanes().first)

        // A script already holding `$MACTERM_SESSION` should be able to paste
        // it into a Shortcuts field.
        let bySession = try await MactermPaneQuery().entities(matching: pane.sessionName)

        #expect(bySession.map(\.id) == [pane.sessionName])
    }

    @Test
    func a_pane_resolves_by_session_name_and_an_unknown_one_is_empty() async throws {
        let (appState, projectStore) = makeHost()
        let api = seedProject(appState, projectStore, name: "api")
        let pane = try #require(appState.workspaces[api.id]?.tabs.first?.splitRoot.allPanes().first)

        let found = try await MactermPaneQuery().entities(for: [pane.sessionName])
        let missing = try await MactermPaneQuery().entities(for: ["macterm-gone-dead"])

        #expect(found.map(\.id) == [pane.sessionName])
        #expect(missing.isEmpty)
    }
}
