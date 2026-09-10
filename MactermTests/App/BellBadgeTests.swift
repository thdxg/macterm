import Foundation
@testable import Macterm
import Testing

/// The pure half of the Dock badge: tab bell states + the `bell-features` set
/// in, a label (or none) out. The AppKit write is not under test.
@MainActor
struct BellBadgeTests {
    /// A two-pane tab with the first `ringing` panes ringing.
    private func tab(ringing: Int = 0) -> TerminalTab {
        let tab = TerminalTab(projectPath: "/", projectID: UUID())
        tab.splitRoot = build(H(pane("a"), pane("b"))).tree
        for p in tab.splitRoot.allPanes().prefix(ringing) {
            p.ringBell()
        }
        return tab
    }

    // MARK: - label

    @Test
    func no_badge_without_the_attention_feature_even_with_bells() {
        #expect(BellBadge.label(bellTabCount: 3, features: []) == nil)
        #expect(BellBadge.label(bellTabCount: 3, features: [.system, .audio, .title, .border]) == nil)
    }

    @Test
    func no_badge_when_nothing_rang() {
        #expect(BellBadge.label(bellTabCount: 0, features: [.attention]) == nil)
    }

    @Test
    func badge_is_the_count_while_attention_is_on() {
        #expect(BellBadge.label(bellTabCount: 1, features: [.attention]) == "1")
        #expect(BellBadge.label(bellTabCount: 12, features: [.system, .attention]) == "12")
        #expect(BellBadge.label(bellTabCount: 99, features: [.attention]) == "99")
    }

    @Test
    func badge_caps_at_99_plus_like_ghostty() {
        #expect(BellBadge.label(bellTabCount: 100, features: [.attention]) == "99+")
        #expect(BellBadge.label(bellTabCount: 4000, features: [.attention]) == "99+")
    }

    // MARK: - tabCount

    @Test
    func counts_tabs_not_panes() {
        let twoRinging = tab(ringing: 2)
        #expect(twoRinging.splitRoot.allPanes().count == 2)
        #expect(twoRinging.hasUnacknowledgedBell)
        #expect(BellBadge.tabCount([twoRinging]) == 1)
    }

    @Test
    func counts_only_tabs_with_an_unacknowledged_bell() {
        let quiet = tab()
        let ringing = tab(ringing: 1)
        let acknowledged = tab(ringing: 1)
        acknowledged.acknowledgeBell()
        #expect(BellBadge.tabCount([quiet, ringing, acknowledged]) == 1)
        #expect(BellBadge.tabCount([TerminalTab]()) == 0)
    }

    // MARK: - Acknowledgment

    @Test
    func looking_at_the_pane_acknowledges_its_bell() throws {
        let ringing = tab(ringing: 1)
        let pane = try #require(ringing.splitRoot.allPanes().first)
        pane.recordUserInteraction()
        #expect(!ringing.hasUnacknowledgedBell)
    }

    @Test
    func a_tab_acknowledges_every_pane_that_rang_not_just_the_focused_one() {
        let ringing = tab(ringing: 2)
        #expect(ringing.acknowledgeBell())
        #expect(ringing.splitRoot.allPanes().allSatisfy { !$0.hasUnacknowledgedBell })
        // Idempotent: nothing left to acknowledge reports no change.
        #expect(!ringing.acknowledgeBell())
    }

    @Test
    func tearing_down_a_pane_takes_its_bell_out_of_the_count() {
        let ringing = tab(ringing: 1)
        for pane in ringing.splitRoot.allPanes() {
            pane.destroySurface()
        }
        #expect(!ringing.hasUnacknowledgedBell)
    }
}

/// The `AppState` half: which events acknowledge a bell, and the one write.
@MainActor
struct BellBadgeAppStateTests {
    /// An AppState with a temp-file store, both badge seams stubbed, and one
    /// project selected. `labels` records every write in order.
    private final class Recorder {
        var labels: [String?] = []
    }

    private func makeAppState(
        features: GhosttyApp.BellFeatures = [.attention],
        appActive: Bool = true
    ) -> (AppState, Recorder, Project) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        let recorder = Recorder()
        state.bellFeatures = { features }
        state.dockBadgeWriter = { recorder.labels.append($0) }
        state.isAppActive = { appActive }
        let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
        state.selectProject(project)
        return (state, recorder, project)
    }

    private func ringingPane(_ state: AppState, _ project: Project) throws -> Pane {
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        pane.ringBell()
        return pane
    }

    @Test
    func a_bell_in_the_active_tab_of_the_active_app_is_seen_at_once_and_never_badges() throws {
        let (state, recorder, project) = makeAppState(appActive: true)
        let pane = try ringingPane(state, project)

        state.paneBellStateDidChange(paneID: pane.id)

        #expect(!pane.hasUnacknowledgedBell)
        #expect(state.dockBadgeLabel == nil)
        // Nothing was ever badged, so nothing needed writing back down.
        #expect(recorder.labels.isEmpty)
    }

    @Test
    func a_bell_in_a_background_tab_badges_and_clears_when_that_tab_is_selected() throws {
        let (state, recorder, project) = makeAppState(appActive: true)
        let background = try #require(state.workspaces[project.id]?.activeTab)
        state.createTab(projectID: project.id, projects: [project])
        let foreground = try #require(state.workspaces[project.id]?.activeTab)
        #expect(foreground.id != background.id)

        let pane = try #require(background.focusedPane)
        pane.ringBell()
        state.paneBellStateDidChange(paneID: pane.id)

        #expect(background.hasUnacknowledgedBell)
        #expect(state.dockBadgeLabel == "1")
        #expect(recorder.labels == ["1"])

        state.selectTab(background.id, projectID: project.id)
        state.syncDockBadge()

        #expect(!background.hasUnacknowledgedBell)
        #expect(state.dockBadgeLabel == nil)
        #expect(recorder.labels == ["1", nil])
    }

    @Test
    func a_bell_while_the_app_is_in_the_background_badges_until_it_comes_forward() throws {
        let (state, recorder, project) = makeAppState(appActive: false)
        let pane = try ringingPane(state, project)

        state.paneBellStateDidChange(paneID: pane.id)

        #expect(pane.hasUnacknowledgedBell)
        #expect(recorder.labels == ["1"])

        state.acknowledgeBellsInActiveTab()
        state.syncDockBadge()

        #expect(!pane.hasUnacknowledgedBell)
        #expect(recorder.labels == ["1", nil])
    }

    @Test
    func the_badge_counts_tabs_across_every_workspace() throws {
        let (state, _, first) = makeAppState(appActive: false)
        let firstPane = try ringingPane(state, first)
        let second = Project(name: "other", path: "/tmp/other", sortOrder: 1)
        state.selectProject(second)
        let secondPane = try ringingPane(state, second)

        state.syncDockBadge()

        #expect(firstPane.hasUnacknowledgedBell)
        #expect(secondPane.hasUnacknowledgedBell)
        #expect(state.dockBadgeLabel == "2")
    }

    @Test
    func dropping_the_attention_feature_clears_a_badge_already_up() throws {
        var features: GhosttyApp.BellFeatures = [.attention]
        let (state, recorder, project) = makeAppState(appActive: false)
        state.bellFeatures = { features }
        _ = try ringingPane(state, project)
        state.syncDockBadge()
        #expect(recorder.labels == ["1"])

        // What a config reload without `attention` leaves behind.
        features = [.system]
        state.syncDockBadge()

        #expect(state.dockBadgeLabel == nil)
        #expect(recorder.labels == ["1", nil])
    }

    @Test
    func nothing_is_badged_at_all_without_the_attention_feature() throws {
        let (state, recorder, project) = makeAppState(features: [.system, .audio], appActive: false)
        _ = try ringingPane(state, project)

        state.syncDockBadge()

        #expect(state.dockBadgeLabel == nil)
        #expect(recorder.labels.isEmpty)
    }

    @Test
    func an_unchanged_label_costs_no_write() throws {
        let (state, recorder, project) = makeAppState(appActive: false)
        _ = try ringingPane(state, project)

        state.syncDockBadge()
        state.syncDockBadge()
        state.syncDockBadge()

        #expect(recorder.labels == ["1"])
    }
}
