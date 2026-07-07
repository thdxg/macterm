import Foundation
@testable import Macterm
import Testing

@MainActor
struct CommandSourceTests {
    // MARK: - Helpers

    private func makeContext(
        seedProject: Bool = true,
        projectPath: String = "/tmp"
    ) -> (PaletteContext, AppState) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        if seedProject {
            let p = Project(name: "proj", path: projectPath, sortOrder: 0)
            store.add(p)
            state.selectProject(p)
        }
        return (PaletteContext(appState: state, projectStore: store), state)
    }

    private func findItem(title: String, in ctx: PaletteContext) -> PaletteItem? {
        CommandSource().emptyItems(context: ctx)?.first { $0.title == title }
    }

    /// Find a command via the QUERY path (fuzzy `items(query:)`), the code that
    /// carries the 6.1 `isEnabled` field-preservation fix.
    private func queryItem(title: String, query: String, in ctx: PaletteContext) -> PaletteItem? {
        CommandSource().items(query: query, context: ctx).first { $0.title == title }
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

    // MARK: - applyLayout muted state

    /// Throws so a broken fixture fails loudly at its own line instead of
    /// surfacing as a misleading later assertion failure.
    private func writeProjectFile(_ yaml: String, in state: AppState) throws {
        let dir = state.projectFiles.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: dir.appendingPathComponent("p.yaml"), atomically: true, encoding: .utf8)
    }

    @Test
    func applyLayout_is_muted_with_hint_when_no_project_file_exists() throws {
        let (ctx, _) = makeContext()
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!item.isEnabled)
        #expect(item.subtitle != nil)
    }

    @Test
    func applyLayout_is_muted_when_project_file_has_no_tabs() throws {
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!item.isEnabled)
    }

    @Test
    func applyLayout_is_enabled_when_project_file_declares_tabs() throws {
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\ntabs:\n  - {}\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
    }

    @Test
    func applyLayout_stays_enabled_when_project_file_is_invalid() throws {
        // Invoking it surfaces the parse-error dialog — hiding or muting the
        // command would bury the error instead.
        let (ctx, state) = makeContext()
        try writeProjectFile("path: /tmp\ntabs:\n  - split: { direction: horizontal, first: {} }\n", in: state)
        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
    }

    @Test
    func applyLayout_is_hidden_without_active_project() {
        let (ctx, _) = makeContext(seedProject: false)
        #expect(findItem(title: AppCommand.applyLayout.title, in: ctx) == nil)
    }

    @Test
    func applyLayout_is_enabled_when_only_a_legacy_layout_exists() throws {
        // Deprecated migration path (#114): no central file, but the project
        // carries a committed `.macterm/layout.yaml` — invoking the command
        // imports it, so it must not be muted. The legacy file lands *after*
        // the project is open (as for any pre-central-directory project,
        // whose snapshot suppresses the first-open import).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-cmdlegacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ctx, _) = makeContext(projectPath: dir.path)

        let legacy = dir.appendingPathComponent(".macterm/layout.yaml")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "tabs:\n  - {}\n".write(to: legacy, atomically: true, encoding: .utf8)

        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
    }

    @Test
    func applyLayout_subtitle_names_duplicate_project_files() throws {
        let (ctx, state) = makeContext()
        let dir = state.projectFiles.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "path: /tmp\ntabs:\n  - {}\n"
            .write(to: dir.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
        try "path: /tmp\n"
            .write(to: dir.appendingPathComponent("b.yaml"), atomically: true, encoding: .utf8)

        let item = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(item.isEnabled)
        let subtitle = try #require(item.subtitle)
        #expect(subtitle.contains("a.yaml"))
        #expect(subtitle.contains("b.yaml"))
    }

    // MARK: - items(query:) — the search path (6.7)

    @Test
    func query_prefix_match_surfaces_command() {
        let (ctx, _) = makeContext()
        // "New Tab" should surface for a prefix of its title.
        #expect(queryItem(title: AppCommand.newTab.title, query: "new t", in: ctx) != nil)
    }

    @Test
    func query_nonmatching_omits_command() {
        let (ctx, _) = makeContext()
        let results = CommandSource().items(query: "zzzznomatch", context: ctx)
        #expect(results.isEmpty)
    }

    /// Regression for the 6.1 bug: a disabled hint row that matches a search
    /// query must stay disabled (muted, unselectable) — the query path used to
    /// drop `isEnabled` when it rebuilt the item.
    @Test
    func query_preserves_isEnabled_on_disabled_hint_row() throws {
        let (ctx, _) = makeContext() // no project file → Apply Layout is a muted hint
        let empty = try #require(findItem(title: AppCommand.applyLayout.title, in: ctx))
        #expect(!empty.isEnabled) // baseline: disabled in the empty state
        let searched = try #require(
            queryItem(title: AppCommand.applyLayout.title, query: "apply", in: ctx)
        )
        #expect(!searched.isEnabled) // must remain disabled through the search path
    }
}
