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
    func two_windows_on_one_tab_render_the_real_tab_once_and_a_mirror_of_it() throws {
        // A pane owns one NSView, which can live in one hierarchy: two windows
        // rendering the same tab fought over every view and the loser drew
        // nothing — the reported blank second window. The second window gets a
        // mirror view: the same sessions, attached a second time.
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let real = try #require(ws.activeTab)
        let source = try #require(real.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)

        let viewA = try #require(state.viewTab(for: project.id, in: a))
        let viewB = try #require(state.viewTab(for: project.id, in: b))
        #expect(!viewA.isMirror)
        #expect(viewA.tab === real)
        #expect(viewB.isMirror)
        #expect(viewB.mirrorOf === real)
        #expect(viewB.tab.splitRoot.allPanes().map(\.sessionName) == real.splitRoot.allPanes().map(\.sessionName))
        #expect(viewB.tab.splitRoot.allPanes().allSatisfy { $0.command == nil })
        #expect(viewB.tab.splitRoot.shapeSignature == real.splitRoot.shapeSignature)
        // Both windows report the same selected tab; only the view differs.
        #expect(state.selectedTab(for: project.id, in: b)?.id == real.id)
    }

    @Test
    func a_mirror_view_is_stable_across_key_window_changes() throws {
        // Ownership is sticky: Cmd-tabbing between the two windows must not
        // swap which one has the real panes (a swap rebuilds both views).
        let state = makeAppState()
        let (project, _) = try seedProject(state, tabs: 1)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let mirror = try #require(state.viewTab(for: project.id, in: b)).tab

        state.noteKeyWindow(b)
        #expect(state.viewTab(for: project.id, in: a)?.isMirror == false)
        #expect(state.viewTab(for: project.id, in: b)?.tab === mirror, "the same shadow, not a rebuilt one")

        state.noteKeyWindow(a)
        #expect(state.viewTab(for: project.id, in: b)?.tab === mirror)
    }

    @Test
    func selecting_a_tab_another_window_owns_yields_a_mirror_not_a_steal() throws {
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
        #expect(state.viewTab(for: project.id, in: b)?.isMirror == false, "b owns the second tab")

        state.selectTab(second.id, projectID: project.id)

        #expect(ws.activeTabID == second.id)
        let viewA = try #require(state.viewTab(for: project.id, in: a))
        #expect(viewA.isMirror, "the key window mirrors rather than taking the panes")
        #expect(viewA.mirrorOf === second)
        #expect(state.viewTab(for: project.id, in: b)?.isMirror == false)
    }

    @Test
    func a_mirror_view_is_rebuilt_when_the_real_tab_changes_shape() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 1)
        let real = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let before = try #require(state.viewTab(for: project.id, in: b)).tab
        #expect(before.splitRoot.allPanes().count == 1)

        let source = try #require(real.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .vertical, projectID: project.id, projectDirectory: "/tmp"
        ))

        let after = try #require(state.viewTab(for: project.id, in: b)).tab
        #expect(after !== before)
        #expect(after.splitRoot.allPanes().count == 2)
        #expect(after.splitRoot.shapeSignature == real.splitRoot.shapeSignature)
    }

    @Test
    func a_mirror_view_is_dropped_when_its_window_moves_on() throws {
        let state = makeAppState()
        let (project, ws) = try seedProject(state, tabs: 2)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        // The key window holds the first tab, so b's selection of it mirrors.
        state.selectTab(ws.tabs[0].id, projectID: project.id)
        state.selectTab(ws.tabs[0].id, projectID: project.id, in: b)
        #expect(state.viewTab(for: project.id, in: b)?.isMirror == true)
        #expect(b.shadowTabs.count == 1)

        state.selectTab(ws.tabs[1].id, projectID: project.id, in: b)

        #expect(b.shadowTabs.isEmpty)
        #expect(state.viewTab(for: project.id, in: b)?.isMirror == false)
    }

    @Test
    func mirror_view_panes_take_part_in_leadership() throws {
        // The mirror's pane is a real zmx client: focusing it claims the pty
        // and dims the real pane in the other window.
        let state = makeAppState()
        state.sendClaim = { _ in true }
        let (project, ws) = try seedProject(state, tabs: 1)
        let real = try #require(ws.activeTab)
        let realPane = try #require(real.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let view = try #require(state.viewTab(for: project.id, in: b))
        let mirrorPane = try #require(view.tab.splitRoot.allPanes().first)
        #expect(state.isMirrored(realPane))
        #expect(state.isLeader(realPane), "the real pane leads until a mirror is focused")

        state.focusMirroredPane(mirrorPane.id, in: view)

        #expect(state.isLeader(mirrorPane))
        #expect(state.nonLeaderPaneIDs(in: real) == [realPane.id])
        #expect(real.focusedPaneID == realPane.id, "focus wrote through to the real tab")
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
        let real = try #require(ws.activeTab)
        let source = try #require(real.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let mirror = try #require(state.viewTab(for: project.id, in: b)).tab
        claimed = []

        state.noteKeyWindow(b)
        #expect(Set(claimed) == Set(mirror.splitRoot.allPanes().map(\.id)))
        #expect(state.nonLeaderPaneIDs(in: real) == Set(real.splitRoot.allPanes().map(\.id)))
        #expect(state.nonLeaderPaneIDs(in: mirror).isEmpty)

        claimed = []
        state.noteKeyWindow(a)
        #expect(Set(claimed) == Set(real.splitRoot.allPanes().map(\.id)))
        #expect(state.nonLeaderPaneIDs(in: real).isEmpty)
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
    func a_rebuilt_mirror_does_not_leave_the_key_window_trusting_a_stale_record() throws {
        // b (key) leads through its mirror. A split in the real tab rebuilds
        // b's mirror: its old clients detach and the record for them is
        // stale. When a becomes key it must CLAIM, not skip on the tree-order
        // guess that its own panes already lead — zmx has handed leadership to
        // whichever client attached next.
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let real = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        state.noteKeyWindow(b)
        #expect(state.viewTab(for: project.id, in: b)?.isMirror == true)
        let source = try #require(real.splitRoot.allPanes().first)
        _ = try #require(state.splitPane(
            source.id, direction: .horizontal, projectID: project.id, projectDirectory: "/tmp"
        ))
        _ = state.viewTab(for: project.id, in: b) // rebuilds the mirror, retiring the old one
        claimed = []

        state.noteKeyWindow(a)

        #expect(Set(claimed) == Set(real.splitRoot.allPanes().map(\.id)))
        for pane in real.splitRoot.allPanes() {
            #expect(state.isLeader(pane))
        }
    }

    @Test
    func a_mirror_client_coming_up_elsewhere_makes_the_key_window_reassert() throws {
        // A fresh client on a session the key window leads is exactly what
        // zmx makes leader when the previous leader detached, so the key
        // window claims again rather than trusting its record.
        let state = makeAppState()
        var claimed: [UUID] = []
        state.sendClaim = { claimed.append($0.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let realPane = try #require(ws.activeTab?.splitRoot.allPanes().first)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(a)
        let mirrorPane = try #require(state.viewTab(for: project.id, in: b)?.tab.splitRoot.allPanes().first)
        #expect(state.isLeader(realPane))
        claimed = []

        state.surfaceDidGetSize(paneID: mirrorPane.id)

        #expect(claimed == [realPane.id])
        #expect(state.isLeader(realPane))
    }

    @Test
    func a_surface_that_gets_its_size_in_the_key_windows_tab_claims_leadership() throws {
        // The claim on key change is refused until a mirror's surface has a
        // size; the surface-sized report re-sends it.
        let state = makeAppState()
        var deliverable = false
        var claimed: [UUID] = []
        state.sendClaim = { pane in
            guard deliverable else { return false }
            claimed.append(pane.id)
            return true
        }
        let (project, ws) = try seedProject(state, tabs: 1)
        let real = try #require(ws.activeTab)
        let a = WindowState(activeProjectID: project.id)
        let b = WindowState(activeProjectID: project.id)
        state.registerWindow(a)
        state.registerWindow(b)
        state.noteKeyWindow(b)
        let mirrorPane = try #require(state.viewTab(for: project.id, in: b)?.tab.splitRoot.allPanes().first)
        #expect(claimed.isEmpty, "nothing recorded while undeliverable")
        #expect(try state.isLeader(#require(real.splitRoot.allPanes().first)))

        deliverable = true
        state.surfaceDidGetSize(paneID: mirrorPane.id)

        #expect(claimed == [mirrorPane.id])
        #expect(state.isLeader(mirrorPane))
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
