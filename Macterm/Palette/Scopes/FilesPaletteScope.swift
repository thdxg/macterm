import AppKit
import Foundation

/// One entry of a project's file index: a file or directory under the
/// project root, by its path relative to it.
struct FileIndexEntry: Equatable {
    let relativePath: String
    let isDirectory: Bool

    var name: String { (relativePath as NSString).lastPathComponent }
    /// The directory the entry is in, relative to the root; empty at the top.
    var parent: String { (relativePath as NSString).deletingLastPathComponent }
    var depth: Int { relativePath.count(where: { $0 == "/" }) }
}

/// The files and directories under a project root, for the palette's Files
/// screen. Pure over the file system: a temp tree is the whole test.
enum FileIndex {
    /// Directories never descended into: dependency and build trees that
    /// would swamp the index and never hold what the user is looking for.
    /// Hidden entries (`.git`, `.build`) are skipped by the enumerator.
    static let excludedDirectories: Set<String> = [
        "node_modules", "build", "DerivedData", "target", "dist", "out",
        "vendor", "Pods", "__pycache__", "venv", ".venv",
    ]
    /// Entries past this many are left out — a tree that large is not
    /// something a palette can show anyway, and the scan has to end.
    static let limit = 20000

    /// Every entry under `root`, shallow first and alphabetical within a
    /// depth, so the top of the list is the project's own top level.
    static func scan(root: URL, limit: Int = limit) -> [FileIndexEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        else { return [] }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        var entries: [FileIndexEntry] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, excludedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            if relative.hasSuffix("/") { relative.removeLast() }
            guard !relative.isEmpty else { continue }
            entries.append(FileIndexEntry(relativePath: relative, isDirectory: isDirectory))
            if entries.count >= limit { break }
        }
        return entries.sorted { ($0.depth, $0.relativePath.lowercased()) < ($1.depth, $1.relativePath.lowercased()) }
    }

    /// The entries `query` matches, best first, listing order breaking ties:
    /// the relative path is the target (so `pal/eng` finds
    /// `Palette/PaletteEngine.swift`), and a match on the name alone counts
    /// as well so a file name's prefix ranks first wherever the file is.
    /// The search index over `entries` (`Macterm/Search/`, built for long
    /// lists): the name is the title field, the relative path the second, so
    /// `pal/eng` finds `Palette/PaletteEngine.swift` and a match on the name
    /// outranks the same match deep in a path. Prepared once per scan, off
    /// the main actor like the scan itself.
    static func searchIndex(for entries: [FileIndexEntry]) -> SearchIndex {
        SearchIndex(entries.map { [$0.name, $0.relativePath] })
    }

    /// A match: the entry, the engine's score (higher is better) and the
    /// offsets in its name the query matched.
    struct Match: Equatable {
        let entry: FileIndexEntry
        let score: Int32
        let highlights: [Int]
    }

    /// The best `limit` entries for `query`, the engine's order; the first
    /// `limit` entries, in listing order, for an empty query.
    static func matches(_ entries: [FileIndexEntry], index: SearchIndex, query: String, limit: Int) -> [Match] {
        let search = SearchQuery(query)
        guard !search.isEmpty else { return entries.prefix(limit).map { Match(entry: $0, score: 0, highlights: []) } }
        return index.search(search, limit: limit).map { match in
            Match(entry: entries[match.index], score: match.score, highlights: index.highlights(search, at: match.index))
        }
    }
}

/// The palette's Files: every file and directory of the active local
/// project, indexed once when the screen opens (`FileIndex.scan`, off the
/// main actor, with `loading` meanwhile) and searched by partial path.
/// Enter opens the pick in a split beside the focused pane — a directory as
/// a shell there, a file in the terminal editor (`TextFileEditor`, as a
/// ⌘-clicked path opens); ⌥↩ opens it with its default app instead.
@MainActor
final class FilesPaletteScope: PaletteScope {
    /// Rows shown at once: the palette draws every row it is given, and a
    /// project has thousands of files.
    static let shownLimit = 50

    let placeholder = "Search files by name or path..."
    private(set) var loading: PaletteLoading?
    private(set) var failure: PaletteFailure?
    private var entries: [FileIndexEntry]?
    private var index: SearchIndex?
    private var root: URL?
    private var task: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private var context: PaletteContext?
    private let scan: @Sendable (URL) -> [FileIndexEntry]

    init(scan: @escaping @Sendable (URL) -> [FileIndexEntry] = { FileIndex.scan(root: $0) }) {
        self.scan = scan
    }

    private static func projectRoot(_ context: PaletteContext) -> (Project, URL)? {
        guard let projectID = context.appState.activeProjectID,
              let project = context.projectStore.projects.first(where: { $0.id == projectID }),
              !project.isRemote
        else { return nil }
        return (project, URL(fileURLWithPath: (project.path as NSString).expandingTildeInPath, isDirectory: true))
    }

    func activate(context: PaletteContext, onChange: @escaping @MainActor () -> Void) {
        self.context = context
        self.onChange = onChange
        guard entries == nil, task == nil, failure == nil else { return }
        startScan()
    }

    func deactivate() {
        task?.cancel()
        task = nil
    }

    func retry() {
        guard task == nil else { return }
        failure = nil
        entries = nil
        index = nil
        startScan()
    }

    private func startScan() {
        guard let context else { return }
        guard let (project, root) = Self.projectRoot(context) else {
            failure = PaletteFailure(title: "No local project to search", detail: nil)
            onChange?()
            return
        }
        self.root = root
        loading = PaletteLoading(message: "Indexing \(project.name)…")
        onChange?()
        let scan = scan
        task = Task { @MainActor [weak self] in
            let (found, index) = await Task.detached(priority: .userInitiated) { () -> ([FileIndexEntry], SearchIndex) in
                let entries = scan(root)
                return (entries, FileIndex.searchIndex(for: entries))
            }.value
            guard let self, !Task.isCancelled else { return }
            task = nil
            loading = nil
            entries = found
            self.index = index
            self.onChange?()
        }
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        self.context = context
        guard let entries, let index, let root, let (project, _) = Self.projectRoot(context) else { return [] }
        let items = FileIndex.matches(entries, index: index, query: query.trimmed, limit: Self.shownLimit).map { match in
            item(for: match, root: root, project: project, context: context)
        }
        return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
    }

    private func item(for match: FileIndex.Match, root: URL, project: Project, context: PaletteContext) -> PaletteItem {
        let entry = match.entry
        let url = root.appendingPathComponent(entry.relativePath, isDirectory: entry.isDirectory)
        let appState = context.appState
        let projects = context.projectStore.projects
        return PaletteItem(
            id: "file:\(entry.relativePath)",
            title: entry.name,
            subtitle: entry.parent.isEmpty ? nil : entry.parent,
            score: -Int(match.score),
            icon: entry.isDirectory ? "folder" : "doc",
            alt: PaletteAltAction(title: "Open with Default App") {
                NSWorkspace.shared.open(url)
            },
            highlights: match.highlights
        ) {
            FilesPaletteActions.openInSplit(url, isDirectory: entry.isDirectory, project: project, appState: appState, projects: projects)
        }
    }
}

/// Opening a Files pick in Macterm: a split beside the project's focused
/// pane, as a shell in the directory or the terminal editor on the file.
@MainActor
enum FilesPaletteActions {
    static func openInSplit(_ url: URL, isDirectory: Bool, project: Project, appState: AppState, projects: [Project]) {
        let path = url.path(percentEncoded: false)
        let command: String? = isDirectory ? nil : TextFileEditor.typedCommand
        let env: [String: String]? = isDirectory ? nil : TextFileEditor.environment(path: path, line: nil)
        let directory = isDirectory ? path : nil
        guard let pane = appState.focusedPane(for: project.id) else {
            appState.createTab(projectID: project.id, projects: projects, command: command, env: env)
            return
        }
        appState.splitPane(
            pane.id,
            direction: .auto(for: pane.nsView?.bounds.size ?? .zero),
            projectID: project.id,
            command: command,
            env: env,
            newPaneWorkingDirectory: directory ?? pane.liveLocalWorkingDirectory() ?? project.path
        )
    }
}
