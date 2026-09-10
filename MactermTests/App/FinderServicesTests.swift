import AppKit
@testable import Macterm
import Testing

/// Finder's "New Macterm Project Here" service. The provider's method name and
/// the `NSMessage` in `Info.plist` are a wire contract AppKit resolves at run
/// time with no compile-time check — a drift means the menu item shows up and
/// silently does nothing — so the plist is read back from the hosting bundle.
@MainActor
struct FinderServicesTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(workspaceStore: WorkspaceStore(fileURL: tmp), projectFiles: ProjectFileStore(directoryURL: dir))
    }

    private func makeProjectStore() -> ProjectStore {
        ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-finder-\(UUID().uuidString).json"))
    }

    // MARK: - Request resolution

    @Test
    func a_file_resolves_to_its_folder_and_one_folder_is_one_project() throws {
        let urls = try [
            URL(fileURLWithPath: "/Users/me/proj/notes.md"),
            URL(fileURLWithPath: "/Users/me/proj", isDirectory: true),
            URL(fileURLWithPath: "/Users/me/other/", isDirectory: true),
            #require(URL(string: "https://example.com/proj")),
        ]
        let paths = FinderServiceRequest.projectPaths(from: urls) { $0.hasDirectoryPath }
        #expect(paths == ["/Users/me/proj", "/Users/me/other"])
    }

    @Test
    func a_folder_is_recognised_without_a_trailing_slash() throws {
        // An NSURL read off the pasteboard carries no trailing slash, so the
        // default check has to ask the file system, not the URL.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-finder-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // `URL(fileURLWithPath:)` would stat the directory and add the slash
        // itself; the hint pins the slashless shape the pasteboard hands over.
        var slashless = dir.path(percentEncoded: false)
        while slashless.hasSuffix("/") {
            slashless.removeLast()
        }
        let bare = URL(filePath: slashless, directoryHint: .notDirectory)
        #expect(!bare.hasDirectoryPath)
        #expect(FinderServiceRequest.projectPaths(from: [bare]) == [ProjectPath.canonicalLocal(slashless)])
    }

    // MARK: - Deferral

    @Test
    func a_request_waits_for_attach_and_the_launch_restore_then_creates_and_selects() {
        let state = makeAppState()
        let store = makeProjectStore()
        let provider = FinderServiceProvider()

        provider.open(paths: ["/Users/me/proj"])
        #expect(store.projects.isEmpty)

        provider.attach(appState: state, projectStore: store)
        // Attached, but the launch restore hasn't run: acting now would be
        // overwritten by `restoreSelection`.
        #expect(store.projects.isEmpty)

        state.restoreWindows(adopting: WindowState())
        #expect(store.projects.map(\.path) == ["/Users/me/proj"])
        #expect(store.projects.map(\.name) == ["proj"])
        #expect(state.activeProjectID == store.projects.first?.id)
    }

    @Test
    func after_the_restore_a_request_acts_immediately_and_selects_the_last_folder() {
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let provider = FinderServiceProvider()
        provider.attach(appState: state, projectStore: store)

        provider.open(paths: ["/Users/me/a", "/Users/me/b"])

        #expect(store.projects.map(\.path) == ["/Users/me/a", "/Users/me/b"])
        #expect(state.activeProjectID == store.projects.last?.id)
    }

    @Test
    func the_service_entry_point_reads_folders_off_the_pasteboard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-finder-pb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let provider = FinderServiceProvider()
        provider.attach(appState: state, projectStore: store)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([dir as NSURL])
        var error: NSString = ""
        provider.newProjectHere(pasteboard, userData: nil, error: &error)

        #expect(error.length == 0)
        #expect(store.projects.map(\.path) == [ProjectPath.canonicalLocal(dir.path(percentEncoded: false))])
    }

    @Test
    func an_empty_selection_reports_an_error_instead_of_creating_anything() {
        let state = makeAppState()
        let store = makeProjectStore()
        state.restoreWindows(adopting: WindowState())
        let provider = FinderServiceProvider()
        provider.attach(appState: state, projectStore: store)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macterm-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("not a path", forType: .string)
        var error: NSString = ""
        provider.newProjectHere(pasteboard, userData: nil, error: &error)

        #expect(error.length > 0)
        #expect(store.projects.isEmpty)
    }

    // MARK: - Info.plist contract

    @Test
    func the_plist_service_names_a_method_the_provider_implements() throws {
        let services = try #require(Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]])
        let entry = try #require(services.first { $0["NSMessage"] as? String == FinderServiceProvider.newProjectMessage })

        let selector = NSSelectorFromString("\(FinderServiceProvider.newProjectMessage):userData:error:")
        #expect(FinderServiceProvider.instancesRespond(to: selector))

        let title = try #require((entry["NSMenuItem"] as? [String: String])?["default"])
        // Built from the display name, so the Debug app's item doesn't collide
        // with the release app's in Finder's menu.
        #expect(title == "New \(appDisplayName) Project Here")
        #expect((entry["NSRequiredContext"] as? [String: String])?["NSTextContent"] == "FilePath")
        #expect((entry["NSSendTypes"] as? [String])?.contains("NSFilenamesPboardType") == true)
    }
}
