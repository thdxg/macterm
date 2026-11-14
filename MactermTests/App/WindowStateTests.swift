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
        // Removal tears the shells down; a window still showing the project
        // would render a workspace that no longer exists.
        let state = makeAppState()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        state.removeProject(project.id)

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
    func two_windows_on_one_tab_draw_the_same_panes_with_a_surface_each() throws {
        // A surface is one window's view of a pane. Two windows that select
        // one tab draw the same pane ids, and each has its own surface, which
        // is its own client of the session.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        #expect(state.selectedTab(for: project.id, in: a) === tab)
        #expect(state.selectedTab(for: project.id, in: b) === tab)
        for pane in tab.splitRoot.allPanes() {
            let forA = pane.surface(for: a.id)
            let forB = pane.surface(for: b.id)
            #expect(forA !== forB)
            #expect(forA.pane === pane)
            #expect(forB.pane === pane)
            #expect(pane.surface(for: a.id) === forA, "the same surface for the same window")
            #expect(pane.surface(for: b.id) === forB)
            #expect(pane.surfaces.count == 2)
            #expect(forA.isFeed, "the first window to draw the pane has its feed")
            #expect(!forB.isFeed)
        }
        #expect(!state.showsTabOfEarlierWindow(a))
        #expect(state.showsTabOfEarlierWindow(b))
    }

    @Test
    func surfaces_are_stable_across_key_window_changes() throws {
        // Cmd-tabbing between the two windows must not rebuild a surface: each
        // surface is a client of the session, with a screen of its own.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = pane.surface(for: a.id)
        let forB = pane.surface(for: b.id)

        state.noteKeyWindow(b)
        state.noteKeyWindow(a)

        #expect(pane.surface(for: a.id) === forA)
        #expect(pane.surface(for: b.id) === forB)
        #expect(pane.surfaces.count == 2)
    }

    @Test
    func selecting_a_tab_another_window_shows_puts_both_windows_on_it() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let first = ws.tabs[0], second = ws.tabs[1]
        state.selectTab(first.id, projectID: project.id)
        state.selectTab(second.id, projectID: project.id, in: b)
        #expect(!state.showsTabOfEarlierWindow(b), "a shows the first tab")

        state.selectTab(second.id, projectID: project.id)

        #expect(ws.activeTabID == second.id)
        #expect(state.selectedTab(for: project.id, in: a) === second)
        #expect(state.selectedTab(for: project.id, in: b) === second)
        #expect(state.showsTabOfEarlierWindow(b))
    }

    @Test
    func a_split_gives_the_new_pane_to_every_window_on_the_tab() throws {
        // One tab, one tree: the panes that a split makes or a close leaves
        // are the panes of every window. Nothing is rebuilt per window.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let source = try #require(tab.splitRoot.allPanes().first)
        let added = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))

        let panes = try #require(state.selectedTab(for: project.id, in: b)).splitRoot.allPanes()
        #expect(panes.map(\.id) == [source.id, added])
        let newPane = try #require(tab.splitRoot.findPane(id: added))
        #expect(newPane.surface(for: a.id) !== newPane.surface(for: b.id))

        state.closePane(source.id, projectID: project.id)
        #expect(state.selectedTab(for: project.id, in: b)?.splitRoot.allPanes().map(\.id) == [added])
    }

    @Test
    func a_tab_holding_one_session_twice_has_a_client_for_each_pane_and_window() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.mirrorPane(source.id, direction: .horizontal, projectID: project.id))

        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        for pane in panes {
            _ = pane.surface(for: a.id)
            _ = pane.surface(for: b.id)
        }
        #expect(Set(panes.map(\.sessionName)) == [source.sessionName])
        #expect(state.clients(of: source.sessionName).count == 4)
    }

    @Test
    func a_surface_is_retired_when_its_window_moves_on() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        // The key window holds the first tab, and b selects it too.
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[0].id, projectID: project.id, in: b)
        let pane = try #require(ws.tabs[0].splitRoot.allPanes().first)
        let forA = pane.surface(for: a.id)
        _ = pane.surface(for: b.id)
        #expect(pane.surfaces.count == 2)

        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)

        #expect(pane.surfaces.count == 1, "b's client goes with its view of the tab")
        #expect(pane.surfaces.first === forA)
    }

    @Test
    func the_feed_passes_to_the_next_surface_when_its_window_moves_on() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[0].id, projectID: project.id, in: b)
        let pane = try #require(ws.tabs[0].splitRoot.allPanes().first)
        _ = pane.surface(for: a.id)
        let forB = pane.surface(for: b.id)
        #expect(!forB.isFeed)

        state.selectTab(ws.tabs[1].id, projectID: project.id)

        #expect(pane.surfaces.count == 1)
        #expect(forB.isFeed, "the pane keeps a feed while any window draws it")
    }

    @Test
    func a_closed_window_gives_its_surfaces_up() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        _ = pane.surface(for: a.id)
        _ = pane.surface(for: b.id)
        #expect(pane.surfaces.count == 2)

        state.unregisterWindow(b)

        #expect(pane.surfaces.count == 1)
        #expect(!state.isMirrored(pane), "one client per session again")
    }

    /// The model makes no surface on its own for a window that never asks. A
    /// surface is a client of the session: a stray one led each new session,
    /// and zmx then dropped ⌃D in the visible pane until a Return (#657).
    @Test
    func a_window_that_does_not_draw_a_pane_gets_no_surface_for_it() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.unregisterWindow(b)

        for _ in 0 ..< 3 {
            let source = try #require(tab.splitRoot.allPanes().last)
            _ = try #require(state.splitPane(
                source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
            ))
        }

        for pane in tab.splitRoot.allPanes() {
            #expect(pane.surfaces.count == 1)
            #expect(!state.isMirrored(pane), "one client per session")
        }
    }

    @Test
    func surfaces_of_two_windows_take_part_in_leadership() throws {
        // A second window's surface is a real client of the session: focusing
        // a pane there claims the pty and dims the other window's view.
        let state = makeAppState()
        state.sendClaim = { _ in true }
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = pane.surface(for: a.id)
        let forB = pane.surface(for: b.id)
        #expect(state.isMirrored(pane))
        #expect(state.isLeader(forA), "a's view leads until b's is focused")

        state.focusPane(pane.id, projectID: project.id, windowID: b.id)

        #expect(state.isLeader(forB))
        #expect(!state.isLeader(forA))
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id) == [pane.id])
        #expect(state.nonLeaderPaneIDs(in: tab, window: b.id).isEmpty)
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
        #expect(state.selectedTab(for: project.id, in: a)?.id == created.id)
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
        #expect(state.selectedTab(for: project.id, in: b)?.id == third.id)
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
        w2.sidebarVisible = false
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
        #expect(!second.sidebarVisible, "sidebar visibility is the window's own, restored with it")
    }

    @Test
    func a_snapshot_that_showed_the_panel_in_a_window_turns_the_one_toggle_on() throws {
        // The panel was per window before it became one toggle for the app.
        // A saved window that showed it turns the toggle on at the restore;
        // the next save writes no per-window value.
        Preferences.shared.projectMemoryPanelVisible = false
        defer { Preferences.shared.projectMemoryPanelVisible = false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        let w1 = WindowState(activeProjectID: p.id)
        writer.registerWindow(w1)
        writer.noteKeyWindow(w1)
        writer.saveWorkspaces()
        // The field as an older build wrote it.
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any] ?? [:]
        var windows = file["windows"] as? [[String: Any]] ?? []
        #expect(windows.count == 1)
        #expect(windows.first?["projectMemoryPanelVisible"] == nil, "a current build writes no per-window value")
        windows[0]["projectMemoryPanelVisible"] = true
        file["windows"] = windows
        try JSONSerialization.data(withJSONObject: file).write(to: tmp)

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        #expect(Preferences.shared.projectMemoryPanelVisible)
        #expect(reader.projectMemoryPanelVisible)
    }

    @Test
    func every_window_reopens_at_its_own_saved_frame() {
        // #496: the frame was left to SwiftUI's autosave, whose key changes
        // every launch, so windows always came back at the default size. It
        // is the window's own snapshot entry now — the first window adopts
        // entry 0's frame, and each restored window its own.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let firstFrame = "100 200 1400 900 0 0 3008 1662 "
        let secondFrame = "1508 9 1492 1645 0 0 3008 1662 "

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        let w1 = WindowState(activeProjectID: p.id)
        let w2 = WindowState(activeProjectID: p.id)
        w1.frame = firstFrame
        w2.frame = secondFrame
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p])
        let first = WindowState()
        reader.registerWindow(first)
        reader.noteKeyWindow(first)
        reader.restoreWindows(adopting: first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.frame == firstFrame)
        #expect(second.frame == secondFrame)

        // A window the user opens afterwards has no saved frame to adopt; it
        // opens wherever the scene puts it.
        let opened = WindowState()
        reader.registerWindow(opened)
        #expect(opened.frame == nil)
    }

    @Test
    func a_window_adopted_before_it_registers_keeps_its_saved_sidebar() {
        // #552: the launch task can run `restoreWindows` before the scene's
        // own window attaches. Its registration then looked like a window the
        // user opened, which reset the restored sidebar to the defaults, and
        // it took the pending entry meant for the second restored window.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q])
        let w1 = WindowState(activeProjectID: p.id, sidebarWidth: 320)
        w1.sidebarVisible = false
        let w2 = WindowState(activeProjectID: q.id, sidebarWidth: 280)
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q])
        let first = WindowState()
        reader.restoreWindows(adopting: first)
        reader.registerWindow(first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(first.sidebarWidth == 320)
        #expect(!first.sidebarVisible)
        #expect(second.activeProjectID == q.id, "the second window still gets its own entry")
        #expect(second.sidebarWidth == 280)

        // A window the user opens afterwards still comes up at the defaults.
        let opened = WindowState(sidebarWidth: 333)
        reader.registerWindow(opened)
        #expect(opened.sidebarWidth == Preferences.defaultSidebarWidth)
    }

    /// A store with one project and one saved window on it, and a fresh
    /// `AppState` that has read it back — the launch, up to `restoreWindows`.
    private func relaunchWithOneSavedWindow() -> (AppState, Project) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        writer.registerWindow(WindowState(activeProjectID: p.id))
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p])
        return (reader, p)
    }

    @Test
    func a_window_adopted_before_it_registers_keeps_the_panes_it_draws() throws {
        // The launch task gives the scene's window its project before the
        // window attaches, and the window draws its tab in that gap.
        // Registration must keep the panes and make no second client.
        let (state, project) = relaunchWithOneSavedWindow()
        let first = WindowState()
        state.restoreWindows(adopting: first)

        let before = try #require(state.selectedTab(for: project.id, in: first))
        let pane = try #require(before.splitRoot.allPanes().first)
        let surface = pane.surface(for: first.id)

        state.registerWindow(first)
        let after = try #require(state.selectedTab(for: project.id, in: first))
        #expect(after === before, "registration keeps the panes the window already draws")
        #expect(pane.surface(for: first.id) === surface)
        #expect(pane.surfaces.count == 1)
    }

    @Test
    func a_registered_window_and_an_adopted_window_show_the_same_tab() {
        let (state, project) = relaunchWithOneSavedWindow()
        let registered = WindowState(activeProjectID: project.id)
        state.registerWindow(registered)
        let first = WindowState()
        state.restoreWindows(adopting: first)

        let tab = state.selectedTab(for: project.id, in: registered)
        #expect(tab != nil)
        #expect(state.selectedTab(for: project.id, in: first) === tab)
    }

    @Test
    func each_window_keeps_its_open_project_sections_across_a_relaunch() {
        // The sections were view state, rebuilt empty at every launch: every
        // project but the active one came back closed. A closed active
        // project must stay closed too, although activation opens it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)
        let r = Project(name: "r", path: "/tmp/r", sortOrder: 2)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.restoreSelection(projects: [p, q, r])
        let w1 = WindowState(activeProjectID: p.id)
        w1.expandedProjects = [q.id, r.id]
        let w2 = WindowState(activeProjectID: q.id)
        w2.expandedProjects = [q.id, p.id]
        writer.registerWindow(w1)
        writer.registerWindow(w2)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.restoreSelection(projects: [p, q, r])
        let first = WindowState()
        reader.restoreWindows(adopting: first)
        reader.registerWindow(first)
        let second = WindowState()
        reader.registerWindow(second)

        #expect(first.activeProjectID == p.id)
        #expect(first.expandedProjects == [q.id, r.id], "the closed active project stays closed")
        #expect(second.expandedProjects == [q.id, p.id])

        // A window the user opens afterwards opens only its active project.
        let opened = WindowState()
        reader.registerWindow(opened)
        #expect(opened.expandedProjects == Set([opened.activeProjectID].compactMap(\.self)))
    }

    @Test
    func activating_a_project_opens_its_section_and_removing_it_forgets_it() {
        let state = makeAppState()
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)
        let q = Project(name: "q", path: "/tmp/q", sortOrder: 1)
        state.restoreSelection(projects: [p, q])
        let window = WindowState(activeProjectID: p.id)
        state.registerWindow(window)
        #expect(window.expandedProjects == [p.id])

        window.expandedProjects.remove(p.id)
        window.activeProjectID = q.id
        #expect(window.expandedProjects == [q.id], "only a change of project opens a section")

        window.activeProjectID = PinnedTabs.projectID
        #expect(window.expandedProjects == [q.id], "the pinned workspace has no section")

        state.removeProject(q.id)
        #expect(!window.expandedProjects.contains(q.id))
    }

    @Test
    func a_snapshot_saved_before_sections_were_persisted_opens_the_active_project() throws {
        let json = #"{"activeProjectID":null,"sidebarWidth":200,"isKey":true}"#
        let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.expandedProjectIDs == nil)
    }

    @Test
    func a_snapshot_saved_before_frames_were_persisted_still_restores() throws {
        // `frame` is optional, so a v6 file written by an older build decodes
        // and its windows open at the default size.
        let json = #"{"activeProjectID":null,"sidebarWidth":200,"isKey":true}"#
        let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.frame == nil)
        #expect(snapshot.sidebarWidth == 200)
    }

    @Test
    func a_window_the_user_opens_comes_up_at_the_default_sidebar_state() {
        // Not at whatever was last dragged in some other (possibly since
        // closed) window, and never collapsed.
        let previous = Preferences.shared.sidebarWidth
        defer { Preferences.shared.sidebarWidth = previous }
        Preferences.shared.sidebarWidth = 333
        let state = makeAppState()
        let project = Project(name: "p", path: "/tmp", sortOrder: 0)
        state.restoreSelection(projects: [project])
        let first = WindowState()
        state.registerWindow(first)
        state.noteKeyWindow(first)
        state.restoreWindows(adopting: first)
        #expect(state.hasRestoredWindows)

        let opened = WindowState()
        opened.sidebarVisible = false
        state.registerWindow(opened)

        #expect(opened.sidebarWidth == Preferences.defaultSidebarWidth)
        #expect(opened.sidebarVisible)
    }

    @Test
    func becoming_key_claims_leadership_for_every_pane_of_the_windows_tab() throws {
        // Leadership is per tab, driven by the key window: fronting the other
        // window must hand the pty to all of its panes at once, without a
        // click in each.
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let panes = tab.splitRoot.allPanes()
        claimed = []

        state.noteKeyWindow(b)
        #expect(Set(claimed) == Set(panes.map { $0.surface(for: b.id).id }))
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id) == Set(panes.map(\.id)))
        #expect(state.nonLeaderPaneIDs(in: tab, window: b.id).isEmpty)

        claimed = []
        state.noteKeyWindow(a)
        #expect(Set(claimed) == Set(panes.map { $0.surface(for: a.id).id }))
        #expect(state.nonLeaderPaneIDs(in: tab, window: a.id).isEmpty)
    }

    @Test
    func becoming_key_leaves_a_same_tab_mirror_pairs_leader_alone() throws {
        // `pane mirror` puts two panes on one session in ONE tab. The whole-tab
        // claim must not hand the pty to whichever pane comes last in tree
        // order — the source lost leadership to its own mirror on every key
        // change.
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let tab = try #require(ws.activeTab)
        let source = try #require(tab.splitRoot.allPanes().first)
        _ = try #require(state.mirrorPane(source.id, direction: .horizontal, projectID: project.id))
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        claimed = []

        state.noteKeyWindow(a)

        #expect(claimed.isEmpty, "the source already leads; nothing moves")
        #expect(state.isLeader(source))
    }

    @Test
    func the_first_remaining_window_becomes_key_when_the_key_window_closes() {
        // AppKit reports the new key window only while the app is active; a
        // headless harness never sees it, and every window read as unfocused.
        let state = makeAppState()
        let a = WindowState()
        let b = WindowState()
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)

        state.unregisterWindow(b)

        #expect(state.keyWindowID == a.id)
    }

    @Test
    func a_window_keeps_its_tab_when_the_key_window_switches_tabs() throws {
        // A window with no record of its own used to fall back to the
        // workspace's active tab — the KEY window's — and so followed every
        // tab switch made in the other window, rebuilding its mirror each time.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let shown = try #require(state.selectedTab(for: project.id, in: b))
        let other = try #require(ws.tabs.first { $0.id != shown.id })

        state.selectTab(other.id, projectID: project.id)

        #expect(state.selectedTab(for: project.id, in: a)?.id == other.id)
        #expect(state.selectedTab(for: project.id, in: b)?.id == shown.id, "b stays where it was")
    }

    @Test
    func a_retired_surface_leaves_no_stale_leader_record() throws {
        // b (key) leads through its surface. b moves to another tab, which
        // retires its surface of this one. The record for it must go, so that
        // a leads again and is not judged against a client that is gone.
        let state = makeAppState()
        state.sendClaim = { _ in true }
        let (project, ws) = try seedProject(state, tabs: 2)
        let pane = try #require(ws.tabs[0].splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[0].id, projectID: project.id, in: b)
        state.noteKeyWindow(b)
        let forA = pane.surface(for: a.id)
        let forB = pane.surface(for: b.id)
        state.focusPane(pane.id, projectID: project.id, windowID: b.id)
        #expect(state.isLeader(forB))
        #expect(!state.isLeader(forA))

        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)

        #expect(pane.surfaces.count == 1)
        #expect(state.isLeader(forA))
        #expect(!state.isMirrored(pane))
    }

    @Test
    func a_client_coming_up_elsewhere_makes_the_key_window_reassert() throws {
        // A fresh client on a session the key window leads is exactly what
        // zmx makes leader when the previous leader detached, so the key
        // window claims again rather than trusting its record.
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let forA = pane.surface(for: a.id)
        let forB = pane.surface(for: b.id)
        #expect(state.isLeader(forA))
        claimed = []

        state.surfaceDidGetSize(surfaceID: forB.id)

        #expect(claimed == [forA.id])
        #expect(state.isLeader(forA))
    }

    @Test
    func a_surface_that_gets_its_size_in_the_key_windows_tab_claims_leadership() throws {
        // The claim on key change is refused until the surface has a size;
        // the surface-sized report re-sends it.
        let state = makeAppState()
        var deliverable = false
        var claimed: [UUID] = []
        state.sendClaim = { surface in
            guard deliverable else { return false }
            claimed.append(surface.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)
        let forB = pane.surface(for: b.id)
        #expect(claimed.isEmpty, "nothing recorded while undeliverable")

        deliverable = true
        state.surfaceDidGetSize(surfaceID: forB.id)

        #expect(claimed == [forB.id])
        #expect(state.isLeader(forB))
    }

    /// The model counts one client, so `isMirrored` is false and the gated
    /// claim never sent. A client the model does not know of could lead,
    /// and zmx then drops the visible pane's control keys. The pane in the
    /// key window's tab claims on its first size whatever the count says.
    @Test
    func the_key_windows_pane_claims_on_first_size_with_one_known_client() throws {
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let pane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.noteKeyWindow(a)
        let surface = pane.surface(for: a.id)
        #expect(!state.isMirrored(pane))
        #expect(claimed.isEmpty, "becoming key claims nothing for a sole client")

        state.surfaceDidGetSize(surfaceID: surface.id)

        #expect(claimed == [surface.id])
        #expect(state.isLeader(pane))
    }

    /// A pane that comes up in a window that is NOT key claims nothing on
    /// its own: leadership follows the key window's tab.
    @Test
    func a_sole_pane_in_a_background_window_does_not_claim_on_first_size() throws {
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)
        let background = try #require(ws.tabs[1].splitRoot.allPanes().first)
        let surface = background.surface(for: b.id)
        claimed = []

        state.surfaceDidGetSize(surfaceID: surface.id)

        #expect(claimed.isEmpty)
    }

    /// A remote pane's zmx lives on the host and may predate the Claim tag,
    /// so the unconditional claim never goes to it either.
    @Test
    func a_remote_pane_never_claims_on_first_size() throws {
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let project = Project(name: "r", path: "me@host:/srv/app", sortOrder: 0)
        state.restoreSelection(projects: [project])
        state.selectProject(project)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        #expect(pane.isRemote)
        let a = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.noteKeyWindow(a)
        let surface = pane.surface(for: a.id)

        state.surfaceDidGetSize(surfaceID: surface.id)

        #expect(claimed.isEmpty)
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

    @Test
    func a_window_on_the_pinned_workspace_follows_its_active_tab() throws {
        // Cmd+T on a pinned tab created the tab and the sidebar selected it,
        // but the window kept rendering the old one: a per-window record for
        // the sentinel (seeded by the restore paths) was read by
        // `selectedTab` while nothing maintained it — the workspace hook,
        // reconcile and align all skip the pinned workspace.
        let state = makeAppState()
        state.zmx = .noop
        state.incubatePane = { _ in }
        _ = try seedProject(state, tabs: 1)
        state.ensurePinnedWorkspace()
        // Through AppState so the tabs get pinned records (selection is
        // record-aware), as Cmd+T's `createTab` does.
        let first = try #require(state.createTab(projectID: PinnedTabs.projectID, projectPath: "/tmp"))
        let window = WindowState(activeProjectID: PinnedTabs.projectID)
        state.registerWindow(window)
        state.noteKeyWindow(window)
        window.activeTabIDs[PinnedTabs.projectID] = first

        let created = try #require(state.createTab(projectID: PinnedTabs.projectID, projectPath: "/tmp"))

        #expect(state.selectedTab(for: PinnedTabs.projectID, in: window)?.id == created)
        state.selectTab(first, projectID: PinnedTabs.projectID, in: window)
        #expect(state.selectedTab(for: PinnedTabs.projectID, in: window)?.id == first)
    }

    @Test
    func restoring_a_window_on_the_pinned_workspace_records_no_tab_for_it() async throws {
        // The pinned selection is restored through the workspace
        // (`pinnedActiveTabID`); the window snapshot's copy of it must not
        // become a stale per-window record.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-\(UUID().uuidString).json")
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-window-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let files = ProjectFileStore(directoryURL: projects)
        let p = Project(name: "p", path: "/tmp", sortOrder: 0)

        let writer = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        writer.zmx = .noop
        writer.incubatePane = { _ in }
        writer.restoreSelection(projects: [p])
        writer.selectProject(p)
        writer.ensurePinnedWorkspace()
        let firstPinned = try #require(writer.createTab(projectID: PinnedTabs.projectID, projectPath: "/tmp"))
        _ = try #require(writer.createTab(projectID: PinnedTabs.projectID, projectPath: "/tmp"))
        writer.selectTab(firstPinned, projectID: PinnedTabs.projectID)
        let w = WindowState(activeProjectID: PinnedTabs.projectID)
        writer.registerWindow(w)
        writer.noteKeyWindow(w)
        writer.saveWorkspaces()

        let reader = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: files)
        reader.zmx = .noop
        reader.incubatePane = { _ in }
        reader.restoreSelection(projects: [p])
        await reader.materializeRestoredPinnedTabs()
        let restored = WindowState()
        reader.registerWindow(restored)
        reader.noteKeyWindow(restored)
        reader.restoreWindows(adopting: restored)

        #expect(restored.activeProjectID == PinnedTabs.projectID)
        #expect(restored.activeTabIDs[PinnedTabs.projectID] == nil)
        let pinned = try #require(reader.pinnedWorkspace)
        #expect(pinned.tabs.count == 2)
        #expect(reader.selectedTab(for: PinnedTabs.projectID, in: restored)?.id == pinned.activeTabID)

        let created = pinned.createTab(projectPath: "/tmp")
        #expect(reader.selectedTab(for: PinnedTabs.projectID, in: restored)?.id == created.id)
    }
}

/// The palette's screens (`PaletteScope`) on the window the user is in.
@MainActor
struct PaletteScopeWindowTests {
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
    func a_screens_chord_opens_it_switches_to_it_and_closes_it() {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)

        state.toggleCommandPalette(scope: .passwords)
        #expect(window.isCommandPaletteVisible)
        #expect(window.paletteScope == .passwords)

        state.toggleCommandPalette(scope: .passwords)
        #expect(!window.isCommandPaletteVisible, "pressed again on its own screen, it closes")

        // Up on the root with a search typed: the chord switches screens and
        // starts that screen's search empty.
        state.commandPaletteQuery = "split"
        state.openCommandPalette(scope: nil)
        state.toggleCommandPalette(scope: .passwords)
        #expect(window.isCommandPaletteVisible)
        #expect(window.paletteScope == .passwords)
        #expect(state.commandPaletteQuery.isEmpty)
    }

    @Test
    func screens_stack_and_pop_back_through_their_frames() {
        let window = WindowState()
        #expect(window.paletteScope == nil)

        window.pushPaletteFrame(PaletteFrame(.passwords))
        window.pushPaletteFrame(PaletteFrame(.files))
        window.pushPaletteFrame(PaletteFrame(.files, pill: PalettePill(title: "feature", icon: "tag")))
        #expect(window.paletteStack.map(\.scopeID) == [.passwords, .files, .files])
        #expect(
            window.paletteStack.map(\.pill.title) == ["Password Manager", "Files", "feature"],
            "a frame is named by its own pill unless the row that opened it says otherwise"
        )
        #expect(window.paletteScope == .files)
        #expect(window.paletteStack[1] != window.paletteStack[2], "two frames of one scope are two frames")

        window.popPaletteFrame()
        #expect(window.paletteStack.count == 2)

        window.popPaletteFrames(above: 2)
        #expect(window.paletteStack.count == 2, "an index past the top pops nothing")
        window.popPaletteFrames(above: 0)
        #expect(window.paletteStack.map(\.scopeID) == [.passwords], "a pill click keeps its own frame")

        window.popPaletteFrame()
        window.popPaletteFrame()
        #expect(window.paletteStack.isEmpty, "popping the root is nothing")
    }

    @Test
    func a_screens_chord_replaces_a_nested_stack_with_that_screen_alone() {
        let state = makeAppState()
        let window = WindowState()
        state.registerWindow(window)
        state.noteKeyWindow(window)

        window.pushPaletteFrame(PaletteFrame(.files))
        window.pushPaletteFrame(PaletteFrame(.passwords))
        state.commandPaletteQuery = "prod"
        state.openCommandPalette(scope: .passwords)
        #expect(window.paletteStack.map(\.scopeID) == [.passwords], "the screen asked for, from the root")
        #expect(state.commandPaletteQuery.isEmpty, "a different stack is a different search")

        // Already alone on that screen: the chord leaves the search typed.
        state.commandPaletteQuery = "prod"
        state.openCommandPalette(scope: .passwords)
        #expect(state.commandPaletteQuery == "prod")

        window.resetPaletteStack()
        #expect(window.paletteStack.isEmpty)
    }

    @Test
    func password_manager_is_a_bindable_command_that_is_a_palette_screen() {
        #expect(AppCommand.passwordManager.hotkeyAction == .passwordManager)
        #expect(HotkeyAction.passwordManager.appCommand == .passwordManager)
        #expect(HotkeyAction.passwordManager.defaultShortcut == "none")
    }
}
