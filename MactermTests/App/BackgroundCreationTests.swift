import Foundation
@testable import Macterm
import Testing

/// Background creation respects every window's selection and warms only
/// unrendered panes. All warmed panes share the normal exit classifier.
@MainActor
struct BackgroundCreationTests {
    // MARK: - Setup

    /// Temp-file stores, so no test touches the developer's real App Support or
    /// `~/.config/macterm`. A no-op zmx so a test can never fork the real
    /// daemon or reap live sessions.
    private func makeAppState() -> AppState {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-bg-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-bg-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.zmx = .noop
        return state
    }

    private func seedProject(_ state: AppState, name: String, path: String) -> Project {
        let project = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(project)
        return project
    }

    // MARK: - No-focus splits and `warmIfUnrendered`

    @Test(arguments: [false, true])
    func noFocusSplit_isNotIncubated_whenTabSelectedByWindow(otherWindowIsKey: Bool) throws {
        let state = makeAppState()
        var warmed: [Pane] = []
        state.incubatePane = { warmed.append($0) }

        let p = seedProject(state, name: "p", path: "/p")
        let q = seedProject(state, name: "q", path: "/q")
        // A selected tab renders at its real split size even when another
        // window is key, so the no-focus split must not be incubated.
        let onP = WindowState(activeProjectID: p.id)
        let onQ = WindowState(activeProjectID: q.id)
        state.registerWindow(onP)
        state.registerWindow(onQ)
        state.noteKeyWindow(otherWindowIsKey ? onQ : onP)

        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let source = try #require(tab.focusedPane)

        let newID = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: p.id,
            newPaneWorkingDirectory: p.path, focus: false
        ))

        #expect(tab.splitRoot.findPane(id: newID) != nil)
        #expect(warmed.isEmpty)
    }

    @Test
    func noFocusSplit_isIncubated_whenNoWindowSelectsTheTab() throws {
        let state = makeAppState()
        var warmed: [Pane] = []
        state.incubatePane = { warmed.append($0) }

        let p = seedProject(state, name: "p", path: "/p")
        // No window at all: SwiftUI never renders the new pane, so it must be
        // started off-screen.
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let source = try #require(tab.focusedPane)

        let newID = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: p.id,
            newPaneWorkingDirectory: p.path, focus: false
        ))

        #expect(warmed.map(\.id) == [newID])
    }

    @Test
    func noFocusSplit_isIncubated_whenChildHiddenBehindZoom() throws {
        let state = makeAppState()
        var warmed: [Pane] = []
        state.incubatePane = { warmed.append($0) }

        let p = seedProject(state, name: "p", path: "/p")
        // The tab IS selected by a window, but the new pane is the zoom-hidden
        // child — the recursive split view does not mount it, so it still
        // warms.
        let window = WindowState(activeProjectID: p.id)
        state.registerWindow(window)
        state.noteKeyWindow(window)

        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let source = try #require(tab.focusedPane)
        tab.toggleZoom(paneID: source.id)

        let newID = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: p.id,
            newPaneWorkingDirectory: p.path, focus: false
        ))

        #expect(tab.zoomedPaneID == source.id)
        #expect(warmed.map(\.id) == [newID])
    }

    // MARK: - No-focus first tab after the last one closed

    @Test
    func noFocusFirstTab_afterLastClosed_isAdoptedByWindowsOnProject() throws {
        let state = makeAppState()
        var warmed: [Pane] = []
        state.incubatePane = { warmed.append($0) }

        let p = seedProject(state, name: "p", path: "/p")
        let q = seedProject(state, name: "q", path: "/q")
        let wsP = try #require(state.workspaces[p.id])
        let wsQ = try #require(state.workspaces[q.id])
        let originalTab = try #require(wsP.activeTab)
        let qTab = try #require(wsQ.activeTab)

        let onP = WindowState(activeProjectID: p.id)
        let onQ = WindowState(activeProjectID: q.id)
        state.registerWindow(onP)
        state.registerWindow(onQ)
        state.noteKeyWindow(onQ)

        // Closing the project's last tab leaves the workspace with no active
        // tab — the invariant a no-focus creation must repair.
        state.closeTab(originalTab.id, projectID: p.id)
        #expect(wsP.tabs.isEmpty)
        #expect(wsP.activeTabID == nil)

        let newTabID = try #require(state.createTab(projectID: p.id, projectPath: p.path, focus: false))

        // The workspace adopts the new tab as active, so the window already on
        // the project renders it (and it is not treated as an unrendered pane
        // to incubate).
        #expect(wsP.activeTabID == newTabID)
        #expect(state.selectedTab(for: p.id, in: onP)?.id == newTabID)
        #expect(warmed.isEmpty)

        // The key window — and the app-wide mirror — stay on the other project.
        #expect(state.activeProjectID == q.id)
        #expect(onQ.activeProjectID == q.id)
        #expect(state.selectedTab(for: q.id, in: onQ)?.id == qTab.id)
        #expect(wsQ.tabs.map(\.id) == [qTab.id])
        #expect(wsQ.activeTabID == qTab.id)
    }

    // MARK: - Exit closure wiring on warmed panes

    @Test
    func warmFocusedProject_wiresExitClosure_onUnseenTab() throws {
        let state = makeAppState()
        // Build the NSView but never a real surface (no shell spawns in the
        // test host); the exit closure still attaches to the warmed view.
        state.incubatePane = { _ = $0.ensureNSView() }
        state.paneNeedsConfirmClose = { _ in false }

        let p = seedProject(state, name: "p", path: "/p")
        let ws = try #require(state.workspaces[p.id])
        let firstTab = try #require(ws.activeTab)

        // A second tab becomes active; the first is now the "unseen" tab.
        let secondTabID = try #require(state.createTab(projectID: p.id, projectPath: p.path))

        state.warmFocusedProject()

        let unseenPane = try #require(firstTab.splitRoot.allPanes().first)
        let view = try #require(unseenPane.nsView)
        #expect(view.onProcessExit != nil)

        // Simulate the shell ending on its own: the wired closure must close
        // the unseen tab (a local pane closes; only its single pane, so the
        // whole tab goes).
        view.onProcessExit?()

        #expect(ws.tabs.map(\.id) == [secondTabID])
    }

    // MARK: - Exit closure reads the pane's project at exit time

    @Test
    func warmedExitClosure_closesInNewProject_afterPinnedToNormalMove() throws {
        let state = makeAppState()
        state.incubatePane = { _ = $0.ensureNSView() }
        state.paneNeedsConfirmClose = { _ in false }

        let origin = seedProject(state, name: "origin", path: "/origin")
        let tab = try #require(state.workspaces[origin.id]?.activeTab)

        // Pin the tab, then warm it while it lives in the pinned workspace —
        // the exit closure is wired there.
        state.pinTab(tab.id, fromProject: origin.id)
        let pinnedTab = try #require(state.pinnedWorkspace?.tabs.first { $0.id == tab.id })
        let pane = try #require(pinnedTab.splitRoot.allPanes().first)

        state.warmStaggered([pane])
        let view = try #require(pane.nsView)
        #expect(view.onProcessExit != nil)

        // Move it into a normal project: the pane's routing identity is
        // rebound, but its session and warmed surface stay put.
        let dest = seedProject(state, name: "dest", path: "/dest")
        state.moveTab(tab.id, from: PinnedTabs.projectID, to: dest.id, destPath: dest.path)
        #expect(pane.projectID == dest.id)

        let wsDest = try #require(state.workspaces[dest.id])

        // Simulate the exit. The closure must read the pane's project NOW
        // (the destination), so the pane — and its single-pane tab — close in
        // the destination project. If it had captured the pinned workspace,
        // the move would leave the tab stranded in the destination.
        view.onProcessExit?()

        #expect(wsDest.tabs.contains { $0.id == tab.id } == false)
        #expect(state.pinnedWorkspace?.tabs.contains { $0.id == tab.id } != true)
    }
}
