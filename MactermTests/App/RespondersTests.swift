import AppKit
@testable import Macterm
import Testing

/// `MainAppResponder` answers every configurable binding by running the
/// `AppCommand` that owns it, so these drive real key events through the
/// responder and assert on the model, not on which branch fired.
@MainActor
struct MainAppResponderTests {
    private struct Fixture {
        let state: AppState
        let projects: ProjectStore
        let responder: MainAppResponder
    }

    private func makeFixture() -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-responder-tests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("workspaces.json")),
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent("projects", isDirectory: true))
        )
        let projects = ProjectStore(fileURL: tmp.appendingPathComponent("projects.json"))
        return Fixture(state: state, projects: projects, responder: MainAppResponder(appState: state, projectStore: projects))
    }

    /// A key-down for `action`'s currently bound chord, built from the same
    /// parsed shortcut the responder matches against.
    private func keyDown(for action: HotkeyAction) throws -> NSEvent {
        let shortcut = try #require(HotkeyRegistry.selectedShortcut(for: action))
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: shortcut.keyToken,
            charactersIgnoringModifiers: shortcut.keyToken,
            isARepeat: false,
            keyCode: shortcut.keyCode
        ))
    }

    @Test
    func a_bound_chord_runs_its_commands_action_against_the_active_project() throws {
        let fx = makeFixture()
        let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
        // In the store as well as selected: the command resolves the project
        // directory for the new pane from `projectStore.projects`.
        fx.projects.add(project)
        fx.state.selectProject(project)
        let tab = try #require(fx.state.workspaces[project.id]?.activeTab)
        #expect(tab.splitRoot.allPanes().count == 1)

        #expect(try fx.responder.handle(keyDown(for: .splitDown)) == .handled)
        #expect(tab.splitRoot.allPanes().count == 2)

        _ = fx.state.workspaces[project.id]?.createTab(projectPath: "/tmp")
        let before = fx.state.workspaces[project.id]?.activeTabID
        #expect(try fx.responder.handle(keyDown(for: .nextTabInProject)) == .handled)
        #expect(fx.state.workspaces[project.id]?.activeTabID != before)
    }

    @Test
    func a_chord_whose_command_does_not_apply_passes_through() throws {
        let fx = makeFixture()
        // No project selected: every project-scoped command's action is nil,
        // and the responder must not claim the keystroke — the same rule that
        // hides the palette row.
        #expect(fx.state.activeProjectID == nil)
        #expect(try fx.responder.handle(keyDown(for: .splitDown)) == .passThrough)
        #expect(try fx.responder.handle(keyDown(for: .nextTabInProject)) == .passThrough)
    }

    @Test
    func an_unbound_key_passes_through() throws {
        let fx = makeFixture()
        fx.state.selectProject(Project(name: "proj", path: "/tmp", sortOrder: 0))
        let plainX = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7
        ))
        #expect(fx.responder.handle(plainX) == .passThrough)
    }

    @Test
    func every_binding_has_an_owning_command_to_dispatch_to() {
        // The dispatch is `action.appCommand.action(in:)`; a `HotkeyAction`
        // without an owning `AppCommand` would trap there in debug builds.
        for action in HotkeyAction.allCases {
            #expect(action.appCommand.hotkeyAction == action)
        }
    }
}
