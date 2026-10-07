import AppKit
@testable import Macterm
import Testing
import UniformTypeIdentifiers

/// Opening a folder or a text file WITH Macterm (Finder "Open With", a Dock
/// drop, `open -a Macterm <path>`): the plist declares what LaunchServices may
/// hand over and `AppDelegate.application(_:open:)` turns a folder into a
/// project and a file into the user's editor. The plist is read back from the
/// hosting bundle because a declared type that the delegate mishandles — or a
/// rank that would make Macterm someone's default — is invisible at compile
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
    func folders_become_projects_and_files_are_kept_as_files() throws {
        let file = URL(fileURLWithPath: "/Users/me/proj/notes.md")
        let remote = try #require(URL(string: "https://example.com/proj"))
        let urls = [
            URL(fileURLWithPath: "/Users/me/proj", isDirectory: true),
            file,
            URL(fileURLWithPath: "/Users/me/proj/", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/other", isDirectory: true),
            remote,
        ]
        let resolution = DocumentOpenRequest.resolve(urls) { $0.hasDirectoryPath }

        // A file is opened as itself — never resolved to its folder.
        #expect(resolution.directories == ["/Users/me/proj", "/Users/me/other"])
        #expect(resolution.files == ["/Users/me/proj/notes.md"])
        #expect(resolution.skipped == [remote])
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
        #expect(DocumentOpenRequest.resolve([bare]).directories == [ProjectPath.canonicalLocal(slashless)])
    }

    // MARK: - Delegate routing

    @Test
    func the_delegate_creates_a_project_for_a_folder_and_opens_a_file_in_it() throws {
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

        state.textFilePlacement = { .split }
        delegate.application(NSApplication.shared, open: [file, dir])

        // The folder's project, which the file then opens in: no second
        // project for the file's folder.
        let project = try #require(store.projects.first)
        #expect(store.projects.map(\.path) == [ProjectPath.canonicalLocal(dir.path(percentEncoded: false))])
        #expect(state.activeProjectID == project.id)
        let editor = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        #expect(editor.env?[TextFileEditor.fileVariable] == (file.path(percentEncoded: false) as NSString).standardizingPath)
        #expect(editor.command == TextFileEditor.typedCommand)
    }

    @Test
    func a_file_outside_every_project_gets_a_project_for_its_folder() throws {
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        state.textFilePlacement = { .split }
        let delegate = AppDelegate()
        delegate.finderServices.attach(appState: state, projectStore: store)

        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/Users/me/scratch/todo.txt")])

        #expect(store.projects.map(\.path) == ["/Users/me/scratch"])
        let editor = try #require(state.workspaces[store.projects[0].id]?.activeTab?.focusedPane)
        #expect(editor.env?[TextFileEditor.fileVariable] == "/Users/me/scratch/todo.txt")
    }

    // MARK: - Project choice

    @Test
    func a_text_file_goes_to_the_deepest_local_project_holding_it() {
        let home = Project(name: "home", path: "/Users/me", sortOrder: 0)
        let app = Project(name: "app", path: "/Users/me/dev/app", sortOrder: 1)
        let sibling = Project(name: "ap", path: "/Users/me/dev/ap", sortOrder: 2)
        let remote = Project(name: "box", path: "me@box:/Users/me/dev/app/src", sortOrder: 3)
        let projects = [home, app, sibling, remote]

        #expect(TextFileProject.project(for: "/Users/me/dev/app/src/x.rs", in: projects, activeProjectID: nil) == app)
        // By whole components: `/dev/app/…` is not inside `/dev/ap`.
        #expect(TextFileProject.project(for: "/Users/me/dev/apple.txt", in: projects, activeProjectID: nil) == home)
    }

    @Test
    func a_text_file_in_no_project_goes_to_the_active_local_project_else_the_first() {
        let first = Project(name: "a", path: "/a", sortOrder: 0)
        let second = Project(name: "b", path: "/b", sortOrder: 1)
        let remote = Project(name: "box", path: "me@box:/srv", sortOrder: 2)

        #expect(TextFileProject.project(for: "/tmp/x", in: [first, second], activeProjectID: second.id) == second)
        // A remote project is never chosen, even when active.
        #expect(TextFileProject.project(for: "/tmp/x", in: [first, remote], activeProjectID: remote.id) == first)
        #expect(TextFileProject.project(for: "/tmp/x", in: [remote], activeProjectID: remote.id) == nil)
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

    @Test
    func a_folder_named_pinned_opens_as_pinned_2() {
        // The folder's own name would collide with the pinned workspace's (see
        // `PinnedTabs.reservesName`); opening the folder must still work.
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let delegate = AppDelegate()
        delegate.finderServices.attach(appState: state, projectStore: store)

        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/Users/me/Pinned", isDirectory: true)])

        #expect(store.projects.map(\.name) == ["Pinned 2"])
        #expect(store.projects.map(\.path) == ["/Users/me/Pinned"])
    }

    // MARK: - Info.plist contract

    @Test
    func the_plist_declares_folders_and_text_files_never_as_the_default() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: types.compactMap { entry in
            (entry["CFBundleTypeName"] as? String).map { ($0, entry) }
        })
        #expect(Set(byName.keys) == ["Folders", "Text Files", "Source Files"])

        for entry in types {
            // Alternate everywhere: Macterm appears in "Open With" but is
            // nobody's default until the user picks it (Change All).
            #expect(entry["LSHandlerRank"] as? String == "Alternate")
            #expect(entry["CFBundleTypeRole"] as? String == "Editor")
        }
        #expect(byName["Folders"]?["LSItemContentTypes"] as? [String] == ["public.directory"])
        #expect(byName["Text Files"]?["LSItemContentTypes"] as? [String] == ["public.text"])
        // No shell scripts or executables run on open, unlike Ghostty: a
        // script opened with Macterm is edited.
        #expect(!types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.unix-executable") == true })

        // The extensions name types macOS doesn't know as text — Go, Rust,
        // TypeScript (which it takes for video) — and each only once.
        let extensions = try #require(byName["Source Files"]?["CFBundleTypeExtensions"] as? [String])
        #expect(Set(extensions).count == extensions.count)
        for ext in ["go", "rs", "ts", "zig"] {
            #expect(extensions.contains(ext))
        }
        // An extension macOS already types as text is covered by public.text.
        for ext in extensions {
            let known = UTType(filenameExtension: ext).map { $0.conforms(to: .text) && $0.isDeclared } ?? false
            #expect(!known, "\(ext) is already public.text")
        }

        #expect(info["MDItemKeywords"] as? String == "Terminal")
    }
}
