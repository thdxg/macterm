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
