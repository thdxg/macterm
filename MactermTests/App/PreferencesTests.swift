import Foundation
@testable import Macterm
import Testing

/// Regression guard: the test suite runs hosted inside the debug app, so
/// `UserDefaults.standard` here is the developer's real
/// `com.thdxg.macterm.debug` domain. `Preferences.shared` must be backed by
/// an ephemeral side suite under test — if it ever falls back to `.standard`,
/// every test that touches a preference (even indirectly) would overwrite the
/// developer's live app state.
@MainActor
struct PreferencesTests {
    @Test
    func shared_writes_do_not_reach_the_standard_defaults_domain() {
        let sentinel = UUID()
        let prior = Preferences.shared.activeProjectID
        defer { Preferences.shared.activeProjectID = prior }

        Preferences.shared.activeProjectID = sentinel

        let standardValue = UserDefaults.standard.string(forKey: Preferences.Keys.activeProjectID)
        #expect(standardValue != sentinel.uuidString)
    }

    /// The original leak: `AppState.selectProject` persists the active project
    /// ID through `Preferences.shared` and pushes it onto the project-recency
    /// list, so seeding a throwaway project in a test used to leave the
    /// developer's app pointing at a dangling UUID ("No project selected" on
    /// next launch) and flush their real recency stack with test UUIDs.
    @Test
    func selectProject_does_not_persist_to_the_standard_defaults_domain() {
        let prior = Preferences.shared.activeProjectID
        defer { Preferences.shared.activeProjectID = prior }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-prefs-tests-\(UUID().uuidString).json")
        let state = AppState(workspaceStore: WorkspaceStore(fileURL: tmp))
        let project = Project(name: "throwaway", path: "/tmp", sortOrder: 0)
        state.selectProject(project)

        #expect(Preferences.shared.activeProjectID == project.id)
        let standardValue = UserDefaults.standard.string(forKey: Preferences.Keys.activeProjectID)
        #expect(standardValue != project.id.uuidString)
        let standardRecency = UserDefaults.standard.stringArray(forKey: "macterm.projectRecency") ?? []
        #expect(!standardRecency.contains(project.id.uuidString))
    }
}
