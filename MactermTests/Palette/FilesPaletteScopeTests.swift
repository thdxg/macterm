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

    /// The cap cuts the tree at its deepest level reached, never a top-level
    /// entry: a depth-first walk spent the budget in whichever directory it
    /// met first, leaving later top-level directories out entirely.
    @Test
    func the_cap_keeps_every_shallower_level_whole() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-files-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in (0 ..< 30).map({ "aaa/deep/f\($0).txt" }) + ["zzz/one.txt", "top.txt"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let capped = FileIndex.scan(root: root, limit: 6).map(\.relativePath)
        #expect(Array(capped.prefix(3)) == ["aaa", "top.txt", "zzz"], "the whole top level, first")
        #expect(capped.contains("aaa/deep") && capped.contains("zzz/one.txt"), "then the next level, whole")
        #expect(capped.count == 6)
    }

    /// A link to a directory is a directory to open, never one to enter (a
    /// link back up the tree would loop), and a directory that can't be read
    /// is skipped rather than ending the walk.
    @Test
    func a_linked_directory_is_listed_unentered_and_an_unreadable_one_is_skipped() throws {
        let root = try makeTree()
        let locked = root.appendingPathComponent("locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("current"),
            withDestinationURL: root.appendingPathComponent("src")
        )
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/up"), withDestinationURL: root)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "x".write(to: locked.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let entries = FileIndex.scan(root: root)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        #expect(byPath["current"]?.isDirectory == true, "a linked directory opens as a directory")
        #expect(byPath["src/up"]?.isDirectory == true)
        #expect(!entries.contains { $0.relativePath.hasPrefix("current/") || $0.relativePath.hasPrefix("src/up/") }, "and is never entered")
        #expect(byPath["locked"]?.isDirectory == true)
        #expect(byPath["locked/secret.txt"] == nil)
        #expect(byPath["src/palette/engine.swift"] != nil, "the walk went on past the unreadable directory")
    }

    @Test
    func a_partial_path_finds_a_file_and_a_name_prefix_ranks_first() throws {
        let entries = try FileIndex.scan(root: makeTree())
        // One session, as the screen keeps: queries that narrow the last and
        // queries that don't must both see every entry they should.
        let session = SearchSession(index: FileIndex.searchIndex(for: entries))
        func paths(_ query: String, limit: Int = 50) -> [String] {
            FileIndex.matches(entries, session: session, query: query, limit: limit).map(\.entry.relativePath)
        }
        #expect(paths("pal/eng") == ["src/palette/engine.swift"])
        #expect(paths("scope") == ["src/palette/scope.swift"])
        let engine = FileIndex.matches(entries, session: session, query: "eng", limit: 1).first
        #expect(engine?.highlights == [0, 1, 2], "the name's matched characters, for the row's emphasis")
        // "s" starts src and scope.swift's name alike; the shorter title wins
        // the tie, and a name match beats the same match deep in a path.
        #expect(paths("s", limit: 2) == ["src", "src/palette/scope.swift"])
        #expect(paths("", limit: 3) == ["docs", "Makefile", "README.md"], "empty: the top of the tree")
        #expect(paths("zzz").isEmpty)
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

    /// With no pane to split beside, a directory still opens where it was
    /// picked — a new tab in it, not one at the project root.
    @Test
    func a_directory_pick_with_no_open_pane_opens_a_tab_in_that_directory() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(path: root.path)
        let state = context.appState
        let project = try #require(context.projectStore.projects.first)
        state.workspaces[project.id]?.tabs.removeAll()
        #expect(state.focusedPane(for: project.id) == nil)

        let src = root.appendingPathComponent("src", isDirectory: true)
        FilesPaletteActions.openInSplit(src, isDirectory: true, project: project, appState: state, projects: context.projectStore.projects)
        let pane = try #require(state.focusedPane(for: project.id))
        #expect(pane.projectPath == ProjectPath.normalizedForStorage(src.path(percentEncoded: false)))
        #expect(pane.command == nil)
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
