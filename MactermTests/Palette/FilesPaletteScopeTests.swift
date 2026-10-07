import Foundation
@testable import Macterm
import Testing

/// The palette's Files: the index of a project's files and directories and
/// the screen over it.
@MainActor
struct FilesPaletteScopeTests {
    /// Counts calls from the scan closure, which runs off the main actor.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() {
            lock.withLock { count += 1 }
        }
    }

    /// A small project tree: files at two depths, a hidden entry, and an
    /// excluded dependency directory.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-files-tests-\(UUID().uuidString)", isDirectory: true)
        let files = [
            "README.md", "Makefile", "src/main.swift", "src/palette/engine.swift", "src/palette/scope.swift",
            "docs/guide.md", ".git/HEAD", ".hidden", "node_modules/left-pad/index.js", "build/out.o",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func makeContext(path: String, remote: Bool = false) -> PaletteContext {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macterm-files-ctx-\(UUID().uuidString)",
            isDirectory: true
        )
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("w.json")),
            projectFiles: ProjectFileStore(directoryURL: base.appendingPathComponent("projects", isDirectory: true))
        )
        let store = ProjectStore(fileURL: base.appendingPathComponent("p.json"))
        let project = Project(name: "proj", path: remote ? "devbox:~/proj" : path, sortOrder: 0)
        store.add(project)
        state.selectProject(project)
        return PaletteContext(appState: state, projectStore: store)
    }

    @Test
    func the_index_is_shallow_first_skips_hidden_and_dependency_trees_and_keeps_directories() throws {
        let root = try makeTree()
        let entries = FileIndex.scan(root: root)
        #expect(entries.map(\.relativePath) == [
            "docs", "Makefile", "README.md", "src",
            "docs/guide.md", "src/main.swift", "src/palette",
            "src/palette/engine.swift", "src/palette/scope.swift",
        ])
        #expect(entries.first { $0.relativePath == "src" }?.isDirectory == true)
        #expect(entries.first { $0.relativePath == "Makefile" }?.isDirectory == false)
        #expect(FileIndex.scan(root: root, limit: 3).count == 3, "a huge tree is cut off")
        #expect(FileIndex.scan(root: root.appendingPathComponent("nope")).isEmpty)
    }

    @Test
    func a_partial_path_finds_a_file_and_a_name_prefix_ranks_first() throws {
        let entries = try FileIndex.scan(root: makeTree())
        #expect(FileIndex.matches(entries, query: "pal/eng", limit: 50).map(\.entry.relativePath) == ["src/palette/engine.swift"])
        let scope = FileIndex.matches(entries, query: "scope", limit: 50).map(\.entry.relativePath)
        #expect(scope == ["src/palette/scope.swift"])
        // "s" starts src, src/main.swift's path and scope.swift's name alike
        // (all score 0); the listing's order breaks the tie, shallow first.
        let s = FileIndex.matches(entries, query: "s", limit: 2).map(\.entry.relativePath)
        #expect(s == ["src", "src/main.swift"])
        #expect(
            FileIndex.matches(entries, query: "", limit: 3).map(\.entry.relativePath) == ["docs", "Makefile", "README.md"],
            "empty: the top of the tree"
        )
        #expect(FileIndex.matches(entries, query: "zzz", limit: 50).isEmpty)
    }

    @Test
    func the_screen_indexes_once_shows_rows_with_an_alt_action_and_filters_by_path() async throws {
        let root = try makeTree()
        let context = makeContext(path: root.path(percentEncoded: false))
        let scans = Counter()
        let scope = FilesPaletteScope(scan: { url in
            scans.increment()
            return FileIndex.scan(root: url)
        })
        var redraws = 0
        scope.activate(context: context) { redraws += 1 }
        #expect(scope.loading?.message == "Indexing proj…")
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).isEmpty)
        for _ in 0 ..< 100 where scope.loading != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scope.loading == nil)
        #expect(scans.value == 1)
        #expect(redraws == 2)

        let all = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(all.map(\.title) == [
            "docs",
            "Makefile",
            "README.md",
            "src",
            "guide.md",
            "main.swift",
            "palette",
            "engine.swift",
            "scope.swift",
        ])
        #expect(all.map(\.subtitle) == [nil, nil, nil, nil, "docs", "src", "src", "src/palette", "src/palette"])
        #expect(all.map(\.icon) == ["folder", "doc", "doc", "folder", "doc", "doc", "folder", "doc", "doc"])
        #expect(all.allSatisfy { $0.alt?.title == "Open with Default App" })
        #expect(all.allSatisfy { $0.opensScope == nil })

        let engine = scope.sections(for: PaletteQuery(raw: "pal/eng"), context: context).flatMap(\.items)
        #expect(engine.map(\.title) == ["engine.swift"])
        #expect(scans.value == 1, "keystrokes filter the index; nothing is scanned again")

        scope.activate(context: context) { redraws += 1 }
        #expect(scans.value == 1, "told again on top of the stack, nothing restarts")
    }

    @Test
    func files_is_a_palettes_command_unavailable_for_a_remote_project() {
        let local = makeContext(path: "/tmp")
        let ctx = AppCommandContext(appState: local.appState, projectStore: local.projectStore)
        #expect(AppCommand.files.category == .palettes)
        #expect(AppCommand.files.paletteScope == .files)
        #expect(AppCommand.files.hotkeyAction == .files)
        #expect(HotkeyAction.files.defaultShortcut == "none")
        #expect(AppCommand.files.action(in: ctx) != nil)
        #expect(AppCommand.files.unavailableNotice(in: ctx) == nil)

        let remote = makeContext(path: "", remote: true)
        let remoteCtx = AppCommandContext(appState: remote.appState, projectStore: remote.projectStore)
        #expect(AppCommand.files.action(in: remoteCtx) == nil)
        #expect(AppCommand.files.unavailableNotice(in: remoteCtx) == "Files aren’t available for remote projects")
        #expect(AppCommand.files.paletteDisabledHint(in: remoteCtx) == "Files aren’t available for remote projects")
        #expect(PaletteScopeID.files.pill.title == "Files")
        #expect(CommandSource().emptyItems(context: local)?.first { $0.title == "Files" }?.opensScope == .files)
    }
}
