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
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-prefs-tests-projects-\(UUID().uuidString)", isDirectory: true)
        // Inject a tempdir ProjectFileStore too, so this never reads/writes the
        // developer's real ~/.config/macterm/projects/ (tempdir-injection rule).
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let project = Project(name: "throwaway", path: "/tmp", sortOrder: 0)
        state.selectProject(project)

        #expect(Preferences.shared.activeProjectID == project.id)
        let standardValue = UserDefaults.standard.string(forKey: Preferences.Keys.activeProjectID)
        #expect(standardValue != project.id.uuidString)
        let standardRecency = UserDefaults.standard.stringArray(forKey: "macterm.projectRecency") ?? []
        #expect(!standardRecency.contains(project.id.uuidString))
    }

    /// The persisted sidebar width is fed straight to
    /// `NSSplitView.setPosition` at launch, so it has to land inside the
    /// column's own bounds: an absent key (never dragged) and a stale value
    /// from a build with different bounds both fall back to the default.
    @Test
    func sidebar_width_is_clamped_to_the_column_bounds() {
        let range = Preferences.sidebarWidthRange
        #expect(Preferences.clampSidebarWidth(nil) == Preferences.defaultSidebarWidth)
        #expect(Preferences.clampSidebarWidth(0) == Preferences.defaultSidebarWidth)
        #expect(Preferences.clampSidebarWidth(range.lowerBound - 40) == range.lowerBound)
        #expect(Preferences.clampSidebarWidth(range.upperBound + 40) == range.upperBound)
        #expect(Preferences.clampSidebarWidth(213.5) == 213.5)
    }

    @Test
    func ghostty_config_matches_ghostty_macos_precedence() {
        let appSupport = "/Application Support/com.mitchellh.ghostty"
        let xdg = "/xdg/ghostty"
        let candidates = [
            "/Application Support/com.mitchellh.ghostty/config.ghostty",
            "/Application Support/com.mitchellh.ghostty/config",
            "/xdg/ghostty/config.ghostty",
            "/xdg/ghostty/config",
        ]

        for expected in candidates {
            #expect(Preferences.preferredGhosttyConfigPath(
                applicationSupportConfigDirectory: appSupport,
                xdgConfigDirectory: xdg,
                fileIsNonEmpty: { $0 == expected }
            ) == expected)
        }

        #expect(Preferences.preferredGhosttyConfigPath(
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg,
            fileIsNonEmpty: { _ in true }
        ) == candidates[0])
    }

    @Test
    func ghostty_config_defaults_to_current_application_support_path() {
        #expect(Preferences.preferredGhosttyConfigPath(
            applicationSupportConfigDirectory: "/Application Support/com.mitchellh.ghostty",
            xdgConfigDirectory: "/xdg/ghostty",
            fileIsNonEmpty: { _ in false }
        ) == "/Application Support/com.mitchellh.ghostty/config.ghostty")
    }
}
