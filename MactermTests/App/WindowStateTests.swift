import AppKit
import Foundation
@testable import Macterm
import Testing

/// Per-window selection (#345).
///
/// `AppState.activeProjectID` is a MIRROR of whichever window is key, so the
/// far larger number of "the frontmost project" call sites keep working
/// unchanged while each window renders its own. These pin both directions of
/// that mirror, which is where the bugs were.
@MainActor
struct WindowStateTests {
    /// Tempdir-backed, like every other AppState test — never the developer's
    /// real Application Support.
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projects)
        )
    }

    @Test
    func a_new_window_opens_on_the_project_the_user_was_looking_at() {
        let state = makeAppState()
        let project = UUID()
        state.activeProjectID = project

        let window = WindowState()
        state.registerWindow(window)

        #expect(window.activeProjectID == project)
    }

    @Test
    func becoming_key_points_the_app_at_that_windows_project() {
        // The mirror's outward direction: polling cadence, remote probes and
        // shell warming all read activeProjectID and mean "the window the user
        // is in".
        let state = makeAppState()
        let a = WindowState(activeProjectID: UUID())
        let b = WindowState(activeProjectID: UUID())
        state.registerWindow(a)
        state.registerWindow(b)

        state.noteKeyWindow(a)
        #expect(state.activeProjectID == a.activeProjectID)

        state.noteKeyWindow(b)
        #expect(state.activeProjectID == b.activeProjectID)
    }

    @Test
    func becoming_key_without_a_project_adopts_rather_than_wiping() {
        // A window registers from the view's window-attach, which happens
        // before the launch task restores the selection — so it can become key
        // with no project. Pushing that nil outward would erase the restored
        // project for the whole app.
        let state = makeAppState()
        let restored = UUID()
        state.activeProjectID = restored
        let window = WindowState()
        window.activeProjectID = nil

        state.noteKeyWindow(window)

        #expect(state.activeProjectID == restored)
        #expect(window.activeProjectID == restored)
    }

    @Test
    func setting_the_app_project_follows_into_the_key_window() {
        // The mirror's inward direction. Most callers still set
        // activeProjectID directly — CLI `project select`, notification
        // navigation, a cross-project tab move — and the window the user is
        // looking at has to follow, or it keeps rendering the old project.
        let state = makeAppState()
        let window = WindowState(activeProjectID: UUID())
        state.registerWindow(window)
        state.noteKeyWindow(window)

        let moved = UUID()
        state.activeProjectID = moved

        #expect(window.activeProjectID == moved)
    }

    @Test
    func selecting_in_a_background_window_leaves_the_app_project_alone() {
        // Otherwise a selection made in a window the user is NOT in would
        // repoint polling and shell warming at it.
        let state = makeAppState()
        let key = WindowState(activeProjectID: UUID())
        let background = WindowState(activeProjectID: UUID())
        state.registerWindow(key)
        state.registerWindow(background)
        state.noteKeyWindow(key)
        let appProject = state.activeProjectID

        let other = UUID()
        state.selectProject(other, in: background)

        #expect(background.activeProjectID == other)
        #expect(state.activeProjectID == appProject)
    }

    @Test
    func a_dialog_belongs_to_the_focused_window() {
        // Every window's scene carries its own copy of the confirmation
        // alerts, so an ungated binding presents in ALL of them — the same
        // failure the DialogHost.settings gate already prevents for Settings.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)

        state.noteKeyWindow(b)
        #expect(state.dialogWindowID == b.id)

        state.noteKeyWindow(a)
        #expect(state.dialogWindowID == a.id)
    }

    @Test
    func a_dialog_still_has_somewhere_to_go_with_no_key_window() {
        // Never nil while a window exists: a staged confirmation with nowhere
        // to appear leaves the action unfinished and unexplained.
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)

        #expect(state.keyWindowID == nil)
        #expect(state.dialogWindowID == window.id)
    }

    @Test
    func a_new_window_opens_at_the_app_wide_sidebar_width() {
        let previous = Preferences.shared.sidebarWidth
        defer { Preferences.shared.sidebarWidth = previous }
        Preferences.shared.sidebarWidth = 275

        #expect(WindowState().sidebarWidth == 275)
    }

    @Test
    func windows_keep_independent_sidebar_widths() {
        // Dragging one window's sidebar must not resize another's.
        let state = makeAppState()
        let a = WindowState(sidebarWidth: 200)
        let b = WindowState(sidebarWidth: 320)
        state.registerWindow(a)
        state.registerWindow(b)

        #expect(a.sidebarWidth == 200)
        #expect(b.sidebarWidth == 320)
    }

    // MARK: - Per-window presentation state

    @Test
    func presentation_flags_belong_to_the_key_window() {
        // The palette, the sidebar and the remote-project sheet used to be
        // app-wide, so every window rendered them. The AppState properties are
        // now mirrors of the key window's copy.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        state.isCommandPaletteVisible = true
        #expect(a.isCommandPaletteVisible)
        #expect(!b.isCommandPaletteVisible)

        state.sidebarVisible = false
        #expect(!a.sidebarVisible)
        #expect(b.sidebarVisible)

        state.noteKeyWindow(b)
        #expect(!state.isCommandPaletteVisible, "the mirror reads the new key window")
        #expect(state.sidebarVisible)
    }

    // MARK: - Windows and termination

    @Test
    func windows_are_not_unregistered_while_terminating() {
        // Quit closes every window; each teardown used to unregister and save,
        // so the termination snapshot was rewritten with one window fewer per
        // close and a relaunch brought back only one.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)

        AppTerminationState.isTerminating = true
        defer { AppTerminationState.isTerminating = false }
        state.unregisterWindow(b)

        #expect(state.windows.count == 2)
    }

    @Test
    func the_key_window_is_recorded_in_the_snapshot() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let store = WorkspaceStore(fileURL: tmp)
        let state = AppState(workspaceStore: store, projectFiles: ProjectFileStore(directoryURL: projects))
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)

        state.saveWorkspaces()

        let saved = store.load().windows
        #expect(saved.map(\.isKey) == [false, true])
    }

    @Test
    func vacating_a_project_clears_every_window_showing_it() {
        // Unload tears the shells down; a window still showing the project
        // would respawn them on the spot through its live surfaces.
        let state = makeAppState()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        state.unloadProject(project.id)

        #expect(a.activeProjectID == nil)
        #expect(b.activeProjectID == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func revealing_a_project_prefers_the_window_already_showing_it() {
        // A notification click or CLI focus for project Q while the user is in
        // a window on P must front Q's window, not repoint P's.
        let state = makeAppState()
        let p = UUID()
        let q = UUID()
        let onP = WindowState(activeProjectID: p)
        let onQ = WindowState(activeProjectID: q)
        state.registerWindow(onP)
        state.registerWindow(onQ)
        state.noteKeyWindow(onP)

        state.revealProject(q)

        #expect(onP.activeProjectID == p, "the window the user was in keeps its project")
        #expect(state.keyWindowID == onQ.id)
        #expect(state.activeProjectID == q)
    }

    @Test
    func revealing_an_unshown_project_takes_the_key_window() {
        let state = makeAppState()
        let p = UUID()
        let q = UUID()
        let window = WindowState(activeProjectID: p)
        state.registerWindow(window)
        state.noteKeyWindow(window)

        state.revealProject(q)

        #expect(window.activeProjectID == q)
    }

    // MARK: - Per-window tab selection

    /// A project with `count` tabs, selected in `state`.
    private func seedProject(_ state: AppState, tabs count: Int) throws -> (Project, Workspace) {
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let ws = try #require(state.workspaces[project.id])
        for _ in 1 ..< count {
            _ = ws.createTab(projectPath: "/tmp")
        }
        return (project, ws)
    }

    @Test
    func two_windows_on_one_project_never_display_the_same_tab() throws {
        // A pane owns one NSView, which can live in one hierarchy: two windows
        // rendering the same tab fought over every view and the loser drew
        // nothing — the reported blank second window.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        let shownA = try #require(state.displayedTab(for: project.id, in: a))
        let shownB = try #require(state.displayedTab(for: project.id, in: b))
        #expect(shownA.id == ws.activeTabID, "the key window shows the workspace's active tab")
        #expect(shownA.id != shownB.id)
    }

    @Test
    func a_window_with_no_free_tab_displays_nothing() throws {
        let state = makeAppState()
        let (project, _) = try seedProject(state, tabs: 1)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        #expect(state.displayedTab(for: project.id, in: a) != nil)
        #expect(state.displayedTab(for: project.id, in: b) == nil)
    }

    @Test
    func the_key_window_takes_the_workspaces_tab_and_the_other_yields() throws {
        // Steal semantics: selecting, in the key window, the tab a background
        // window shows moves it here and the other window falls back.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let bTab = try #require(state.displayedTab(for: project.id, in: b))

        state.selectTab(bTab.id, projectID: project.id)

        #expect(ws.activeTabID == bTab.id)
        #expect(state.displayedTab(for: project.id, in: a)?.id == bTab.id)
        #expect(state.displayedTab(for: project.id, in: b)?.id != bTab.id)
    }

    @Test
    func switching_key_window_hands_the_workspace_tab_over_without_swapping() throws {
        // Cmd-tab between two windows on one project must not swap their
        // content: each keeps its own tab, and the workspace's active tab
        // follows whichever is key.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let aTab = try #require(state.displayedTab(for: project.id, in: a))
        let bTab = try #require(state.displayedTab(for: project.id, in: b))

        state.noteKeyWindow(b)
        #expect(ws.activeTabID == bTab.id)
        #expect(state.displayedTab(for: project.id, in: a)?.id == aTab.id)
        #expect(state.displayedTab(for: project.id, in: b)?.id == bTab.id)

        state.noteKeyWindow(a)
        #expect(ws.activeTabID == aTab.id)
        #expect(state.displayedTab(for: project.id, in: b)?.id == bTab.id)
    }

    @Test
    func creating_a_tab_in_the_key_window_records_it_there() throws {
        // Every writer of Workspace.activeTabID — create, close, cycle, the
        // CLI — reaches the key window's record through the workspace hook.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.noteKeyWindow(a)

        let created = ws.createTab(projectPath: "/tmp")

        #expect(a.activeTabIDs[project.id] == created.id)
        #expect(state.displayedTab(for: project.id, in: a)?.id == created.id)
    }

    @Test
    func a_background_window_selects_its_own_tab() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 3)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let before = ws.activeTabID
        let third = ws.tabs[2]

        state.selectTab(third.id, projectID: project.id, in: b)

        #expect(ws.activeTabID == before, "a background selection leaves the key window alone")
        #expect(state.displayedTab(for: project.id, in: b)?.id == third.id)
    }

    @Test
    func mirroring_a_tab_attaches_every_session_a_second_time() throws {
        // How the same work reaches two windows: the tab renders once, but its
        // sessions can be attached any number of times.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let source = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let sourcePane = try #require(source.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            sourcePane.id,
            direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let sourceSessions = source.splitRoot.allPanes().map(\.sessionName)

        let mirrorID = try #require(state.mirrorTab(source.id, projectID: project.id, in: b))
        let mirror = try #require(ws.tabs.first { $0.id == mirrorID })

        #expect(mirror.splitRoot.allPanes().map(\.sessionName) == sourceSessions)
        #expect(mirror.splitRoot.allPanes().allSatisfy { $0.command == nil })
        #expect(state.displayedTab(for: project.id, in: b)?.id == mirrorID)
        #expect(ws.activeTabID == source.id, "the key window keeps its tab")
        for pane in source.splitRoot.allPanes() {
            #expect(state.isLeader(pane))
        }
        for pane in mirror.splitRoot.allPanes() {
            #expect(!state.isLeader(pane))
        }
    }

    @Test
    func restored_windows_take_their_entries_in_order() {
        // The FIFO: each restored window pops its own snapshot entry as it
        // registers, so the second window gets the second project and so on.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q])
        writer.selectProject(p)
        writer.selectProject(q)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: q.id, sidebarWidth: 333)
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.noteKeyWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(second.activeProjectID == q.id)
        #expect(second.sidebarWidth == 333)
    }

    @Test
    func one_window_state_per_nswindow() {
        // SwiftUI instantiates a view — and its @State — more than once per
        // real window, so two instances each proposed their own WindowState
        // and the app grew a phantom window on every launch. The NSWindow is
        // the only thing that is genuinely one-per-window.
        let state = makeAppState()
        let nsWindow = NSWindow()
        let first = WindowState()
        let second = WindowState()

        let a = state.canonicalWindowState(for: nsWindow, proposed: first)
        let b = state.canonicalWindowState(for: nsWindow, proposed: second)

        #expect(a === first)
        #expect(b === first)
        #expect(state.windows.count == 1)

        state.forgetWindowState(for: nsWindow)
        #expect(state.windows.isEmpty)
    }

    @Test
    func distinct_nswindows_get_distinct_states() {
        let state = makeAppState()
        let one = NSWindow()
        let two = NSWindow()

        let a = state.canonicalWindowState(for: one, proposed: WindowState())
        let b = state.canonicalWindowState(for: two, proposed: WindowState())

        #expect(a !== b)
        #expect(state.windows.count == 2)
    }
}
