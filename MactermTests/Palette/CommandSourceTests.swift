import Foundation
@testable import Macterm
import Testing

@MainActor
struct CommandSourceTests {
    // MARK: - Helpers

    private func makeContext(seedProject: Bool = true) -> (PaletteContext, AppState) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let state = AppState(workspaceStore: WorkspaceStore(fileURL: tmp))
        let store = ProjectStore(fileURL: storeTmp)
        if seedProject {
            let p = Project(name: "proj", path: "/tmp", sortOrder: 0)
            store.add(p)
            state.selectProject(p)
        }
        return (PaletteContext(appState: state, projectStore: store), state)
    }

    private func findItem(title: String, in ctx: PaletteContext) -> PaletteItem? {
        CommandSource().emptyItems(context: ctx)?.first { $0.title == title }
    }

    /// The rename actions defer setting `renaming…ID` to the next main-queue
    /// tick (so the sidebar row's TextField exists before it takes first
    /// responder — see `AppCommand.action(in:)`). Spin the run loop so that
    /// deferred work lands before asserting.
    private func flushMainQueue() async {
        // Enqueue behind any pending DispatchQueue.main.async work; main-queue
        // FIFO ordering guarantees the deferred set has run once this resumes.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - renameTab command availability

    @Test
    func renameTab_command_present_when_active_project_has_tab() {
        let (ctx, _) = makeContext()
        #expect(findItem(title: AppCommand.renameTab.title, in: ctx) != nil)
    }

    @Test
    func renameTab_command_absent_when_no_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.renameTab.title, in: ctx) == nil)
    }

    // MARK: - renameTab action

    @Test
    func renameTab_action_registers_postPaletteAction() throws {
        let (ctx, state) = makeContext()
        let item = try #require(findItem(title: AppCommand.renameTab.title, in: ctx))
        item.action()
        #expect(state.postPaletteAction != nil)
    }

    @Test
    func renameTab_postPaletteAction_sets_sidebarVisible_and_renamingTabID() async throws {
        let (ctx, state) = makeContext()
        let activeTabID = try #require(
            state.activeProjectID.flatMap { state.workspaces[$0]?.activeTabID }
        )
        let item = try #require(findItem(title: AppCommand.renameTab.title, in: ctx))
        item.action()
        state.postPaletteAction?()
        await flushMainQueue()
        #expect(state.sidebarVisible)
        #expect(state.renamingTabID == activeTabID)
    }

    @Test
    func renameTab_postPaletteAction_targets_active_tab_at_time_of_action() async throws {
        let (ctx, state) = makeContext()
        let projectID = try #require(state.activeProjectID)
        let ws = try #require(state.workspaces[projectID])
        let firstTabID = try #require(ws.activeTabID)

        // Create a second tab and make it active.
        let secondTab = ws.createTab(projectPath: "/tmp")
        ws.selectTab(secondTab.id)
        #expect(ws.activeTabID == secondTab.id)

        // Build the palette item — it captures the active tab at item-build time.
        let item = try #require(findItem(title: AppCommand.renameTab.title, in: ctx))

        // Switch back to the first tab before executing.
        ws.selectTab(firstTabID)
        item.action()
        state.postPaletteAction?()
        await flushMainQueue()

        // renamingTabID should be the tab that was active when the item was built.
        #expect(state.renamingTabID == secondTab.id)
        _ = firstTabID
    }

    // MARK: - renameProject command availability

    @Test
    func renameProject_command_present_when_active_project_exists() {
        let (ctx, _) = makeContext()
        #expect(findItem(title: AppCommand.renameProject.title, in: ctx) != nil)
    }

    @Test
    func renameProject_command_absent_when_no_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.renameProject.title, in: ctx) == nil)
    }

    // MARK: - renameProject action

    @Test
    func renameProject_action_registers_postPaletteAction() throws {
        let (ctx, state) = makeContext()
        let item = try #require(findItem(title: AppCommand.renameProject.title, in: ctx))
        item.action()
        #expect(state.postPaletteAction != nil)
    }

    @Test
    func renameProject_postPaletteAction_sets_sidebarVisible_and_renamingProjectID() async throws {
        let (ctx, state) = makeContext()
        let projectID = try #require(state.activeProjectID)
        let item = try #require(findItem(title: AppCommand.renameProject.title, in: ctx))
        item.action()
        state.postPaletteAction?()
        await flushMainQueue()
        #expect(state.sidebarVisible)
        #expect(state.renamingProjectID == projectID)
    }

    @Test
    func renameProject_does_not_set_renamingTabID() async throws {
        let (ctx, state) = makeContext()
        let item = try #require(findItem(title: AppCommand.renameProject.title, in: ctx))
        item.action()
        state.postPaletteAction?()
        await flushMainQueue()
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renameTab_does_not_set_renamingProjectID() async throws {
        let (ctx, state) = makeContext()
        let item = try #require(findItem(title: AppCommand.renameTab.title, in: ctx))
        item.action()
        state.postPaletteAction?()
        await flushMainQueue()
        #expect(state.renamingProjectID == nil)
    }
}
