import AppIntents
import AppKit
import Foundation
@testable import Macterm
import Testing

/// The intents' `perform()` paths, driven against injected stores the way
/// `ControlHandlerTests` drives the CLI's handler.
///
/// Serialized as a suite: `MactermIntentHost.shared` and
/// `IntentPermissionGate.shared` are singletons (App Intents are instantiated
/// by the system, so they cannot be handed anything), and swift-testing runs
/// suites in parallel. Panes here never build a surface — there is no window —
/// so every action that needs one asserts the `noSurface` contract instead.
@Suite(.serialized)
@MainActor
struct MactermIntentsTests {
    // MARK: - Fixtures

    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intent-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intent-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
    }

    private func makeProjectStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intent-tests-store-\(UUID().uuidString).json"))
    }

    /// Attach the host and open the permission gate — the state a running app
    /// is in once `installResponders` has run and the user has allowed.
    private func makeHost() -> (AppState, ProjectStore) {
        let appState = makeAppState()
        let projectStore = makeProjectStore()
        MactermIntentHost.shared.attachForTesting(appState: appState, projectStore: projectStore)
        IntentPermissionGate.shared.resetForTesting()
        IntentPermissionGate.shared.access = { .allow }
        return (appState, projectStore)
    }

    private func teardown() {
        IntentPermissionGate.shared.resetForTesting()
    }

    private func seedProject(
        _ appState: AppState,
        _ projectStore: ProjectStore,
        name: String = "demo",
        path: String = "/tmp"
    ) -> Project {
        let project = Project(name: name, path: path, sortOrder: projectStore.projects.count)
        projectStore.add(project)
        appState.selectProject(project)
        return project
    }

    /// A delegate shaped like the one `MainWindow.onAppear` leaves behind, with
    /// no real windows so nothing on the developer's screen is touched.
    ///
    /// The caller must hold the return value: `AppState.appDelegate` is weak
    /// (in production the delegate is owned by
    /// `@NSApplicationDelegateAdaptor`), so a discarded one deallocates
    /// immediately and the intent reports `.appUnavailable`.
    private func attachDelegate(_ appState: AppState, _ projectStore: ProjectStore) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.appState = appState
        delegate.projectStore = projectStore
        delegate.windowLister = { [] }
        delegate.openInitialWindow = {}
        appState.appDelegate = delegate
        return delegate
    }

    // MARK: - The permission gate is in front of every intent

    @Test
    func a_denied_intent_never_touches_the_app() async {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        _ = seedProject(appState, projectStore)
        IntentPermissionGate.shared.access = { .deny }
        let before = projectStore.projects.count

        let intent = FocusMactermProjectIntent()
        intent.project = MactermProjectEntity(projectStore.projects[0])

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
        #expect(projectStore.projects.count == before)
    }

    // MARK: - Projects

    @Test
    func new_project_creates_and_selects_it() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-new-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: dir)
        _ = try await intent.perform()

        #expect(projectStore.projects.count == 1)
        // The folder's own basename, like the picker and `project create` —
        // never a friendlier invented name.
        #expect(projectStore.projects[0].name == dir.lastPathComponent)
        #expect(appState.activeProjectID == projectStore.projects[0].id)
    }

    @Test
    func new_project_takes_an_explicit_name_over_the_folder_basename() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-named-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: dir)
        intent.name = "  API  "
        _ = try await intent.perform()

        // Trimmed, because a stray space in a Shortcuts text field is invisible.
        #expect(projectStore.projects[0].name == "API")
        #expect(appState.activeProjectID == projectStore.projects[0].id)
    }

    @Test
    func new_project_on_a_missing_folder_is_bad_input() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-absent-\(UUID().uuidString)", isDirectory: true)

        let intent = NewMactermProjectIntent()
        intent.folder = IntentFile(fileURL: missing)

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
        #expect(projectStore.projects.isEmpty)
        #expect(appState.workspaces.isEmpty)
    }

    @Test
    func a_project_entity_naming_a_removed_project_is_not_found() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let entity = MactermProjectEntity(project)
        appState.removeProject(project.id)
        projectStore.remove(id: project.id)

        let intent = FocusMactermProjectIntent()
        intent.project = entity

        // An entity is a token, not a handle: a shortcut written weeks ago has
        // to be able to say the thing is gone.
        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    // MARK: - Tabs

    @Test
    func new_tab_lands_in_the_named_project_and_returns_it() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let before = appState.workspaces[project.id]?.tabs.count ?? 0

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        let result = try await intent.perform()

        let tabs = try #require(appState.workspaces[project.id]?.tabs)
        #expect(tabs.count == before + 1)
        #expect(result.value?.id == tabs.last?.id)
    }

    @Test
    func new_tab_passes_the_command_through_as_spawn_time_input() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        intent.command = "  npm run dev  "
        _ = try await intent.perform()

        let tab = try #require(appState.workspaces[project.id]?.tabs.last)
        let pane = try #require(tab.splitRoot.allPanes().first)
        // `Pane.command` is the layout `run:` / libghostty `initial_input`
        // path, not a paste — trimmed, because a trailing space in a Shortcuts
        // text field is invisible.
        #expect(pane.command == "npm run dev")
    }

    @Test
    func new_tab_with_a_blank_command_spawns_a_plain_shell() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)

        let intent = NewMactermTabIntent()
        intent.project = MactermProjectEntity(project)
        intent.command = "   "
        _ = try await intent.perform()

        let pane = try #require(appState.workspaces[project.id]?.tabs.last?.splitRoot.allPanes().first)
        #expect(pane.command == nil)
    }

    @Test
    func focus_tab_selects_it_in_its_own_project() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        _ = appState.createTab(projectID: project.id, projects: projectStore.projects)
        let workspace = try #require(appState.workspaces[project.id])
        let first = try #require(workspace.tabs.first)
        try appState.selectTab(#require(workspace.tabs.last).id, projectID: project.id)

        let intent = FocusMactermTabIntent()
        intent.tab = MactermTabEntity(
            first,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )
        _ = try await intent.perform()

        #expect(workspace.activeTabID == first.id)
    }

    @Test
    func close_tab_ends_it_when_nothing_is_running() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        _ = appState.createTab(projectID: project.id, projects: projectStore.projects)
        let workspace = try #require(appState.workspaces[project.id])
        let doomed = try #require(workspace.tabs.last)
        let before = workspace.tabs.count

        let intent = CloseMactermTabIntent()
        intent.tab = MactermTabEntity(
            doomed,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )
        _ = try await intent.perform()

        #expect(workspace.tabs.count == before - 1)
        #expect(!workspace.tabs.contains { $0.id == doomed.id })
    }

    @Test
    func the_close_refusal_reads_the_same_busy_verdict_the_app_guards_on() {
        // The intent's guard is `Pane.needsConfirmClose`, i.e. this function —
        // the one every busy-close guard in the app reads (pane/tab close,
        // project unload, the CLI's `busy` error, the quit dialog). A shortcut
        // can run unattended, so a busy tab gets that typed refusal rather than
        // the confirmation dialog the UI stages, exactly like `tab close`
        // without `--force`.
        //
        // It is asserted here rather than through `perform()` because
        // `needsConfirmClose` short-circuits on `hasSurface`: a pane in a
        // windowless test never builds a surface and so always reads idle,
        // which is why the close test above closes instead of refusing.
        let busy = ForegroundSample(
            name: "btop",
            isIdleShell: false,
            origin: .processTable(pid: nil),
            sampledAt: Date()
        )
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: busy,
            executionState: .running,
            isRemote: false,
            hasSurface: true,
            surfaceBusy: true
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: busy,
            executionState: .running,
            isRemote: false,
            hasSurface: false,
            surfaceBusy: true
        ))
    }

    // MARK: - Panes

    @Test
    func a_pane_entity_is_keyed_on_the_restart_stable_session_name() throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)

        let entity = MactermPaneEntity(pane, projectID: project.id, in: ctx)

        // NOT `pane.id`: pane UUIDs are fresh on every restore, so a shortcut
        // keyed on one would break silently at the first relaunch.
        #expect(entity.id == pane.sessionName)
        #expect(entity.id != pane.id.uuidString)
        #expect(try IntentTargets.pane(session: entity.id, in: ctx).pane === pane)
    }

    @Test
    func running_a_command_in_a_pane_with_no_surface_reports_no_surface() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)

        let intent = RunCommandInMactermPaneIntent()
        intent.command = "ls"
        intent.submit = true
        intent.pane = MactermPaneEntity(pane, projectID: project.id, in: ctx)

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func running_an_empty_command_is_rejected_before_the_pane_is_resolved() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = RunCommandInMactermPaneIntent()
        intent.command = ""
        intent.submit = true
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func an_unparseable_key_chord_is_bad_input_not_a_silent_no_op() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = SendKeyToMactermPaneIntent()
        intent.key = "ctrl+nonsense"
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    @Test
    func the_key_chord_grammar_is_the_keybind_grammar() {
        // The whole point of routing through `HotkeyRegistry.parseShortcut` is
        // that a shortcut can send what a user could bind.
        for chord in ["ctrl+c", "escape", "up", "ctrl+\\", "j", "space"] {
            #expect(HotkeyRegistry.parseShortcut(chord) != nil, "\(chord) should parse")
        }
    }

    @Test
    func pane_details_answer_from_the_pane_without_a_surface() throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)
        pane.foregroundProcessName = "hx"

        #expect(GetMactermPaneDetailsIntent.value(of: .id, for: pane) == pane.id.uuidString)
        #expect(GetMactermPaneDetailsIntent.value(of: .session, for: pane) == pane.sessionName)
        // No live pwd without a surface, so the project's own path stands in —
        // the same pair `pane list` reports.
        #expect(GetMactermPaneDetailsIntent.value(of: .workingDirectory, for: pane) == pane.projectPath)
        #expect(GetMactermPaneDetailsIntent.value(of: .foregroundProcess, for: pane) == "hx")
        // A nil is a real answer ("no surface yet"), not a failure.
        #expect(GetMactermPaneDetailsIntent.value(of: .size, for: pane) == nil)
    }

    @Test
    func reading_a_pane_with_no_surface_reports_no_surface() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let pane = try #require(appState.workspaces[project.id]?.tabs.first?.splitRoot.allPanes().first)

        let intent = GetMactermPaneContentsIntent()
        intent.scrollback = false
        intent.pane = MactermPaneEntity(
            pane,
            projectID: project.id,
            in: AppCommandContext(appState: appState, projectStore: projectStore)
        )

        await #expect(throws: MactermIntentError.self) { try await intent.perform() }
    }

    // MARK: - Keybinds and commands

    @Test
    func the_keybind_picker_covers_every_hotkey_action_exactly() {
        let picker = Set(MactermKeybind.allCases.map(\.rawValue))
        let actions = Set(HotkeyAction.allCases.map(\.rawValue))
        // The list is a hand-written copy by necessity (the metadata extractor
        // rejects a computed `caseDisplayRepresentations`), so this is what
        // keeps it honest: a new keybind fails here rather than quietly missing
        // from Shortcuts.
        #expect(picker == actions)
        #expect(MactermKeybind.allCases.allSatisfy { $0.hotkeyAction != nil })
    }

    @Test
    func every_keybind_label_is_its_own_command_title() {
        for keybind in MactermKeybind.allCases {
            let action = try? #require(keybind.hotkeyAction)
            guard let action else { continue }
            let label = MactermKeybind.caseDisplayRepresentations[keybind]?.title.key
            #expect(label == action.appCommand.title, "label for \(keybind.rawValue)")
        }
    }

    @Test
    func invoking_a_keybind_runs_the_shared_app_command_action() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let project = seedProject(appState, projectStore)
        let delegate = attachDelegate(appState, projectStore)
        let before = appState.workspaces[project.id]?.tabs.count ?? 0

        let intent = InvokeMactermKeybindIntent()
        intent.keybind = .newTab
        let result = try await intent.perform()

        #expect(result.value == true)
        // The action ran through `AppCommand.newTab.action(in:)` — the same
        // closure the palette, the menu bar and the Dock menu run.
        #expect(appState.workspaces[project.id]?.tabs.count == before + 1)
        #expect(appState.appDelegate === delegate)
    }

    @Test
    func a_keybind_that_does_not_apply_returns_false_instead_of_failing() async throws {
        let (appState, projectStore) = makeHost()
        defer { teardown() }
        let delegate = attachDelegate(appState, projectStore)
        // No project, so `AppCommand.newTab.action(in:)` is nil.
        #expect(appState.activeProjectID == nil)

        let intent = InvokeMactermKeybindIntent()
        intent.keybind = .newTab
        let result = try await intent.perform()

        // A shortcut branches on this rather than erroring out — the command
        // simply didn't apply, which is not the same as a failure.
        #expect(result.value == false)
        #expect(appState.appDelegate === delegate)
    }

    @Test
    func the_quick_terminal_prepares_nothing_and_the_palette_fronts_a_window() {
        // Shared with the Dock menu (`DockMenu.Preparation`) rather than
        // decided again: an intent arrives in exactly the state a Dock pick
        // does — app not activated, no window fronted.
        #expect(DockMenu.preparation(for: .toggleQuickTerminal) == DockMenu.Preparation.none)
        #expect(DockMenu.preparation(for: .toggleCommandPalette) == .frontTerminalWindow)
        #expect(DockMenu.preparation(for: .newTab) == .frontTerminalWindow)
    }
}
