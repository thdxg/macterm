import AppKit
@testable import Macterm
import Testing

/// Opening a folder WITH Macterm (Finder "Open With", a Dock drop,
/// `open -a Macterm <dir>`): the plist declares what LaunchServices may hand
/// over and `AppDelegate.application(_:open:)` turns it into projects. The
/// plist is read back from the hosting bundle because a declared type that the
/// delegate mishandles — or a file type creeping in — is invisible at compile
/// time.
@MainActor
struct OpenFolderTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: ProjectFileStore(directoryURL: dir))
    }

    private func makeProjectStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-open-\(UUID().uuidString).json"))
    }

    // MARK: - Resolution

    @Test
    func folders_become_projects_and_files_are_skipped_not_resolved_to_their_folder() throws {
        let file = URL(fileURLWithPath: "/Users/me/proj/notes.md")
        let remote = try #require(URL(string: "https://example.com/proj"))
        let urls = [
            URL(fileURLWithPath: "/Users/me/proj", isDirectory: true),
            file,
            URL(fileURLWithPath: "/Users/me/proj/", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/other", isDirectory: true),
            remote,
        ]
        let resolution = FolderOpenRequest.resolve(urls) { $0.hasDirectoryPath }

        // The file's folder is already a project here, and it still is NOT
        // what makes the file acceptable — a file is dropped, full stop.
        #expect(resolution.directories == ["/Users/me/proj", "/Users/me/other"])
        #expect(resolution.skipped == [file, remote])
    }

    @Test
    func a_folder_is_recognised_without_a_trailing_slash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-open-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var slashless = dir.path(percentEncoded: false)
        while slashless.hasSuffix("/") {
            slashless.removeLast()
        }
        let bare = URL(filePath: slashless, directoryHint: .notDirectory)
        #expect(!bare.hasDirectoryPath)
        #expect(FolderOpenRequest.resolve([bare]).directories == [ProjectPath.canonicalLocal(slashless)])
    }

    // MARK: - Delegate routing

    @Test
    func the_delegate_creates_and_selects_a_project_for_a_folder_and_ignores_a_file() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-open-delegate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("README.md")
        try Data().write(to: file)

        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let delegate = AppDelegate()
        delegate.finderServices.attach(appState: state, projectStore: store)

        delegate.application(NSApplication.shared, open: [file, dir])

        #expect(store.projects.map(\.path) == [ProjectPath.canonicalLocal(dir.path(percentEncoded: false))])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func a_folder_opened_during_launch_waits_for_the_restore() {
        let state = makeAppState()
        let store = makeProjectStore()
        let delegate = AppDelegate()
        delegate.finderServices.attach(appState: state, projectStore: store)

        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/Users/me/proj", isDirectory: true)])
        // Not yet: `restoreSelection` would overwrite the selection.
        #expect(store.projects.isEmpty)

        state.restoreWindows(adopting: WindowState())
        #expect(store.projects.map(\.path) == ["/Users/me/proj"])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func opening_the_same_folder_twice_makes_two_projects() {
        // A directory is not an identity (see `ProjectStore.create`): a second
        // open is a second project, exactly like the folder picker.
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let delegate = AppDelegate()
        delegate.finderServices.attach(appState: state, projectStore: store)
        let url = URL(fileURLWithPath: "/Users/me/proj", isDirectory: true)

        delegate.application(NSApplication.shared, open: [url])
        delegate.application(NSApplication.shared, open: [url])

        #expect(store.projects.map(\.path) == ["/Users/me/proj", "/Users/me/proj"])
        #expect(state.activeProjectID == store.projects.last?.id)
    }

    // MARK: - Info.plist contract

    @Test
    func the_plist_declares_folders_and_nothing_else() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        let folders = try #require(types.first)

        // Exactly `public.directory`: no file type, no shell script, no
        // executable — files are out of scope, and a declared file type
        // would put Macterm in "Open With" for something the delegate drops.
        #expect(folders["LSItemContentTypes"] as? [String] == ["public.directory"])
        #expect(folders["CFBundleTypeExtensions"] == nil)
        #expect(folders["CFBundleTypeName"] as? String == "Folders")
        #expect(folders["CFBundleTypeRole"] as? String == "Editor")
        // Alternate keeps Finder the default opener for a folder.
        #expect(folders["LSHandlerRank"] as? String == "Alternate")

        #expect(info["MDItemKeywords"] as? String == "Terminal")
    }
}
