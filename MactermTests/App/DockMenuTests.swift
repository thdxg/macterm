import AppKit
@testable import Macterm
import Testing

/// The Dock icon's context menu is rendered from `AppCommand`, through the
/// same `action(in:)` the menu bar and palette run — these pin that the built
/// `NSMenu` matches `DockMenu`'s declaration and that a pick lands in the
/// shared action path rather than a hand-rolled handler.
@MainActor
struct DockMenuTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: ProjectFileStore(directoryURL: dir))
    }

    private func makeProjectStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-dock-\(UUID().uuidString).json"))
    }

    /// A delegate the way `MainWindow.onAppear` leaves it: state objects
    /// attached, no real windows (the lister is empty so nothing on the
    /// developer's screen is touched).
    private func makeDelegate(appState: AppState, projectStore: ProjectStore) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.appState = appState
        delegate.projectStore = projectStore
        delegate.windowLister = { [] }
        delegate.openInitialWindow = {}
        return delegate
    }

    // MARK: - Shape

    @Test
    func the_menu_is_built_from_app_commands_in_declaration_order() throws {
        let state = makeAppState()
        let store = makeProjectStore()
        let delegate = makeDelegate(appState: state, projectStore: store)

        let menu = try #require(delegate.applicationDockMenu(NSApp))

        let titles = menu.items.map(\.title)
        let commands = menu.items.map { $0.representedObject as? AppCommand }
        // Every item dispatches to the delegate, none carries a key equivalent
        // (the Dock renders no chords, and the live binding lives in the menu
        // bar via HotkeyMenuSync).
        let allTargetTheDelegate = menu.items.allSatisfy { $0.target === delegate && $0.action != nil }
        let noneHasAChord = menu.items.allSatisfy(\.keyEquivalent.isEmpty)

        #expect(menu.items.count == DockMenu.commands.count)
        #expect(titles == DockMenu.commands.map(DockMenu.title(for:)))
        #expect(commands == DockMenu.commands)
        #expect(allTargetTheDelegate)
        #expect(noneHasAChord)
    }

    @Test
    func the_menu_offers_ghosttys_four_items() {
        #expect(DockMenu.commands == [.newWindow, .newTab, .openProject, .toggleQuickTerminal])
        #expect(DockMenu.commands.map(DockMenu.title(for:)) == [
            "New Window", "New Tab", "New Project…", "Toggle Quick Terminal",
        ])
        // Every title is an `AppCommand`'s own title or the menu bar's override
        // for it — never a string of the Dock menu's own.
        for command in DockMenu.commands where command != .openProject {
            #expect(DockMenu.title(for: command) == command.title)
        }
    }

    @Test
    func no_custom_menu_before_the_window_hands_over_the_state_objects() {
        let delegate = AppDelegate()
        #expect(delegate.applicationDockMenu(NSApp) == nil)
        delegate.appState = makeAppState()
        #expect(delegate.applicationDockMenu(NSApp) == nil)
    }

    // MARK: - Enablement follows `action(in:)`

    @Test
    func an_item_is_enabled_exactly_when_its_command_applies() throws {
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let delegate = makeDelegate(appState: state, projectStore: store)

        // No project yet: New Tab has nothing to act on, the rest stand.
        let withoutProject = try #require(delegate.applicationDockMenu(NSApp))
        let enabledWithout = withoutProject.items.map(\.isEnabled)
        #expect(!withoutProject.autoenablesItems)
        #expect(enabledWithout == [true, false, true, true])

        let project = store.create(name: "proj", path: "/tmp/proj")
        state.selectProject(project)

        // Rebuilt on the next right-click, it reads the new state.
        let withProject = try #require(delegate.applicationDockMenu(NSApp))
        let enabledWith = withProject.items.map(\.isEnabled)
        #expect(enabledWith == [true, true, true, true])
    }

    // MARK: - A pick runs the shared action path

    @Test
    func picking_new_window_runs_app_commands_own_action() throws {
        let state = makeAppState()
        let store = makeProjectStore()
        let delegate = makeDelegate(appState: state, projectStore: store)
        var opened = 0
        state.openNewWindow = { opened += 1 }

        let menu = try #require(delegate.applicationDockMenu(NSApp))
        let item = try #require(menu.items.first { $0.representedObject as? AppCommand == .newWindow })
        let action = try #require(item.action)
        _ = item.target?.perform(action, with: item)

        // `AppCommand.newWindow` → `AppState.requestNewWindow` → the scene's
        // open-untitled hook: the same route ⌘N and the File menu take.
        #expect(opened == 1)
    }

    @Test
    func picking_new_tab_fronts_a_terminal_window_and_then_creates_the_tab() throws {
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let project = store.create(name: "proj", path: "/tmp/proj")
        state.selectProject(project)
        let delegate = makeDelegate(appState: state, projectStore: store)
        var windowRequests = 0
        delegate.openInitialWindow = { windowRequests += 1 }
        let before = try #require(state.workspaces[project.id]?.tabs.count)

        delegate.performDockMenuCommand(.newTab)

        // With no window at all (#241), the pick asks for one — the tab it
        // makes has to render somewhere — and still creates the tab.
        let after = state.workspaces[project.id]?.tabs.count
        #expect(windowRequests == 1)
        #expect(after == before + 1)
    }

    @Test
    func a_command_that_stopped_applying_is_a_no_op() {
        let state = makeAppState()
        let store = makeProjectStore()
        let delegate = makeDelegate(appState: state, projectStore: store)

        // No project: New Tab's action is nil. Must not trap, must not touch
        // the workspaces.
        delegate.performDockMenuCommand(.newTab)

        #expect(state.workspaces.isEmpty)
    }

    // MARK: - Preparation

    @Test
    func window_bound_picks_front_a_window_and_the_quick_terminal_keeps_focus_where_it_is() {
        #expect(DockMenu.preparation(for: .newTab) == .frontTerminalWindow)
        #expect(DockMenu.preparation(for: .openProject) == .frontTerminalWindow)
        #expect(DockMenu.preparation(for: .newWindow) == .activate)
        #expect(DockMenu.preparation(for: .toggleQuickTerminal) == .none)
    }
}
