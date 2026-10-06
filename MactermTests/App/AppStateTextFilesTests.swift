import Foundation
@testable import Macterm
import Testing

/// Opening a text file in the user's terminal editor: a ⌘-clicked path in a
/// pane, and a file Finder hands Macterm (`AppState+TextFiles`).
@MainActor
struct AppStateTextFilesTests {
    private func makeAppState(placement: TextFilePlacement, command: String = "hx") -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: ProjectFileStore(directoryURL: dir))
        state.textFileSettings = { (command, placement) }
        state.opensTextFileHere = { _ in true }
        return state
    }

    /// A real directory holding `src/main.rs`, since a click only opens a file
    /// that exists.
    private func makeProjectDirectory() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-textfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("fn main() {}\n".utf8).write(to: dir.appendingPathComponent("src/main.rs"))
        return ProjectPath.canonicalLocal(dir.path(percentEncoded: false))
    }

    private func seedProject(_ state: AppState, path: String) -> Project {
        let project = Project(name: "proj", path: path, sortOrder: 0)
        state.selectProject(project)
        return project
    }

    // MARK: - Clicked links

    @Test
    func a_clicked_path_with_a_line_opens_the_editor_in_a_split_beside_the_pane() throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = makeAppState(placement: .split)
        let project = seedProject(state, path: root)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let clicked = try #require(tab.focusedPane)
        clicked.ensureNSView().currentPwd = root

        #expect(state.openClickedLink("src/main.rs:12:4", in: clicked, projects: [project]))

        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let editor = try #require(panes.first { $0.id != clicked.id })
        #expect(tab.focusedPaneID == editor.id)
        #expect(editor.command == TextFileEditor.typedCommand)
        #expect(editor.env == [
            TextFileEditor.fileVariable: root + "/src/main.rs",
            TextFileEditor.lineVariable: "12",
            TextFileEditor.commandVariable: "hx",
        ])
    }

    @Test
    func the_tab_placement_opens_the_editor_in_a_new_tab() throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = makeAppState(placement: .tab)
        let project = seedProject(state, path: root)
        let workspace = try #require(state.workspaces[project.id])
        let clicked = try #require(workspace.activeTab?.focusedPane)
        clicked.ensureNSView().currentPwd = root

        #expect(state.openClickedLink(root + "/src/main.rs", in: clicked, projects: [project]))

        #expect(workspace.tabs.count == 2)
        let editor = try #require(workspace.activeTab?.focusedPane)
        #expect(editor.id != clicked.id)
        #expect(editor.env?[TextFileEditor.fileVariable] == root + "/src/main.rs")
        #expect(editor.env?[TextFileEditor.lineVariable] == nil)
    }

    @Test
    func a_click_that_names_no_local_file_is_left_to_the_system_opener() throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = makeAppState(placement: .split)
        let project = seedProject(state, path: root)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let clicked = try #require(tab.focusedPane)
        clicked.ensureNSView().currentPwd = root

        #expect(!state.openClickedLink("https://example.com:8080", in: clicked, projects: [project]))
        #expect(!state.openClickedLink("src/missing.rs:3", in: clicked, projects: [project]))
        // A directory isn't a text file.
        #expect(!state.openClickedLink("src", in: clicked, projects: [project]))
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func a_click_in_a_remote_pane_is_left_to_the_system_opener() throws {
        let state = makeAppState(placement: .split)
        let project = seedProject(state, path: "me@host:/srv/app")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let clicked = try #require(tab.focusedPane)

        // The file is on the host; nothing local can open it.
        #expect(!state.openClickedLink("/etc/hosts:1", in: clicked, projects: [project]))
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Files from Finder

    @Test
    func a_file_from_finder_splits_the_projects_focused_pane() throws {
        let state = makeAppState(placement: .split, command: "")
        let project = seedProject(state, path: "/proj")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let before = try #require(tab.focusedPaneID)

        let newID = try #require(state.openTextFile("/proj/README.md", line: nil, inProject: project.id, projects: [project]))

        #expect(tab.splitRoot.allPanes().count == 2)
        #expect(newID != before)
        let editor = try #require(tab.splitRoot.findPane(id: newID))
        // No command configured: the shell's $EDITOR decides.
        #expect(editor.env == [TextFileEditor.fileVariable: "/proj/README.md"])
    }

    @Test
    func a_file_from_finder_gets_its_own_tab_under_the_tab_placement() throws {
        let state = makeAppState(placement: .tab)
        let project = seedProject(state, path: "/proj")
        let workspace = try #require(state.workspaces[project.id])

        let newID = try #require(state.openTextFile("/proj/a.go", line: 9, inProject: project.id, projects: [project]))

        #expect(workspace.tabs.count == 2)
        #expect(workspace.activeTab?.focusedPaneID == newID)
    }
}
