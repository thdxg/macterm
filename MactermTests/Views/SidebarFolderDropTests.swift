import AppKit
@testable import Macterm
import Testing

/// Folders dragged onto the sidebar open as projects (`SidebarFolderDropTarget`).
@MainActor
struct SidebarFolderDropTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: ProjectFileStore(directoryURL: dir))
    }

    private func makeProjectStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-folder-drop-\(UUID().uuidString).json"))
    }

    @Test
    func a_drag_names_its_folders_and_ignores_its_files() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-folder-drop-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, folder as NSURL])

        #expect(SidebarFolderDropTarget.DropView.directories(on: pasteboard) == [
            ProjectPath.canonicalLocal(folder.path(percentEncoded: false)),
        ])
    }

    @Test
    func a_drag_of_files_alone_names_nothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("/Users/me/proj", forType: .string)

        #expect(SidebarFolderDropTarget.DropView.directories(on: pasteboard).isEmpty)
    }

    @Test
    func a_drop_on_a_background_window_selects_the_project_there_and_leaves_the_key_window_alone() {
        let state = makeAppState()
        let store = makeProjectStore()
        let key = WindowState()
        state.restoreWindows(adopting: key)
        state.noteKeyWindow(key)
        let other = WindowState()
        state.registerWindow(other)
        let before = state.activeProjectID

        let project = state.openProjects(atPaths: ["/Users/me/a", "/Users/me/b"], store: store, in: other)

        #expect(store.projects.map(\.path) == ["/Users/me/a", "/Users/me/b"])
        #expect(project?.id == store.projects.last?.id)
        #expect(other.activeProjectID == project?.id)
        #expect(state.activeProjectID == before)
    }
}
