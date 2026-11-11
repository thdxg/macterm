import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateSessionRestartTests {
    private actor Killed {
        private(set) var names: Set<String> = []
        func append(_ name: String) {
            names.insert(name)
        }

        func settle(expecting count: Int) async {
            for _ in 0 ..< 200 where names.count < count {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func makeState(killed: Killed? = nil) -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let files = ProjectFileStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true))
        let state = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        if let killed {
            state.zmx = ZmxClient(
                executableURL: { nil },
                isBundled: { true },
                killSession: { await killed.append($0) },
                killRemoteSession: { _, _, _ in },
                listSessions: { [] },
                endV1Sessions: { _ in true }
            )
        }
        return state
    }

    private func command(_ state: AppState, _ projectStore: ProjectStore = ProjectStore()) -> (@MainActor () -> Void)? {
        AppCommand.restartSession.action(in: AppCommandContext(appState: state, projectStore: projectStore))
    }

    @Test
    func the_badge_shows_only_for_a_tab_with_an_older_session() throws {
        let state = makeState()
        state.selectProject(Project(name: "p", path: "/tmp", sortOrder: 0))
        let tab = try #require(state.workspaces.values.first?.activeTab)
        #expect(!state.tabRunsOlderSession(tab))
        state.outdatedSessions = ["another-session"]
        #expect(!state.tabRunsOlderSession(tab))
        state.outdatedSessions = try [#require(tab.splitRoot.allPanes().first).sessionName]
        #expect(state.tabRunsOlderSession(tab))
    }

    @Test
    func the_command_is_available_only_with_an_older_session_in_the_active_tab() throws {
        let state = makeState()
        let projectStore = ProjectStore()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.selectProject(project)
        #expect(command(state, projectStore) == nil)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        state.outdatedSessions = [pane.sessionName]
        #expect(command(state, projectStore) != nil)
    }

    @Test
    func a_restart_replaces_only_the_older_panes_and_ends_their_sessions() async throws {
        let killed = Killed()
        let state = makeState(killed: killed)
        state.paneNeedsConfirmClose = { _ in false }
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.selectProject(project)
        state.splitPane(direction: .horizontal, projectID: project.id, projects: [project])
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let old = panes[0], kept = panes[1]
        tab.focusedPaneID = old.id
        state.outdatedSessions = [old.sessionName]

        state.requestRestartSessions(tabID: tab.id, projectID: project.id)

        let after = tab.splitRoot.allPanes()
        #expect(after.count == 2)
        #expect(after.contains { $0.id == kept.id })
        #expect(!after.contains { $0.id == old.id })
        #expect(!after.contains { $0.sessionName == old.sessionName })
        #expect(tab.focusedPaneID != old.id)
        #expect(tab.focusedPaneID.map { id in after.contains { $0.id == id } } == true)
        #expect(state.outdatedSessions.isEmpty)
        await killed.settle(expecting: 1)
        #expect(await killed.names == [old.sessionName])
        #expect(state.pendingDialog == nil)
    }

    @Test
    func a_busy_pane_asks_before_the_restart() throws {
        let state = makeState()
        state.paneNeedsConfirmClose = { _ in true }
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.selectProject(project)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let old = try #require(tab.splitRoot.allPanes().first)
        state.outdatedSessions = [old.sessionName]

        state.requestRestartSessions(tabID: tab.id, projectID: project.id)

        #expect(state.pendingDialog?.kind == .restartSessions(tabID: tab.id, projectID: project.id))
        #expect(tab.splitRoot.allPanes().first?.id == old.id)

        state.confirmPendingDialog()
        #expect(tab.splitRoot.allPanes().first?.id != old.id)
    }
}
