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
    /// Hidden entries (`.git`, `.build`, `.venv`) are skipped as hidden.
    static let excludedDirectories: Set<String> = [
        "node_modules", "build", "DerivedData", "target", "dist", "out",
        "vendor", "Pods", "__pycache__", "venv",
    ]
    /// Entries past this many are left out — a tree that large is not
    /// something a palette can show anyway, and the scan has to end.
    static let limit = 20000

    /// Every entry under `root`, shallow first and alphabetical within a
    /// depth, so the top of the list is the project's own top level.
    ///
    /// Walked a level at a time, so `limit` cuts the tree at its deepest
    /// level reached — never a top-level entry because a depth-first walk
    /// happened to spend the budget in one directory first. A symbolic link
    /// to a directory is listed as a directory and never entered (a link back
    /// up the tree would loop); a package (`.app`) is listed as one entry. An
    /// unreadable directory is skipped, and a cancelled task stops the walk.
    static func scan(root: URL, limit: Int = limit) -> [FileIndexEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var entries: [FileIndexEntry] = []
        var level: [(url: URL, relative: String)] = [(root, "")]
        walk: while !level.isEmpty {
            var next: [(url: URL, relative: String)] = []
            for (directory, prefix) in level {
                if Task.isCancelled { break walk }
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
                else { continue }
                for child in children.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
                    let values = try? child.resourceValues(forKeys: keys)
                    let isLink = values?.isSymbolicLink ?? false
                    var isDirectory = values?.isDirectory ?? false
                    if isLink {
                        var target: ObjCBool = false
                        isDirectory = FileManager.default.fileExists(atPath: child.path(percentEncoded: false), isDirectory: &target)
                            && target.boolValue
                    }
                    let name = child.lastPathComponent
                    if isDirectory, excludedDirectories.contains(name) { continue }
                    let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    entries.append(FileIndexEntry(relativePath: relative, isDirectory: isDirectory))
                    if entries.count >= limit { break walk }
                    if isDirectory, !isLink, values?.isPackage != true { next.append((child, relative)) }
                }
            }
            level = next
        }
        return entries.sorted { ($0.depth, $0.relativePath.lowercased()) < ($1.depth, $1.relativePath.lowercased()) }
    }

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
    /// `limit` entries, in listing order, for an empty query. Searched
    /// through `session`, so a keystroke that narrows the query searches
    /// only the last one's matches.
    static func matches(_ entries: [FileIndexEntry], session: SearchSession, query: String, limit: Int) -> [Match] {
        let search = SearchQuery(query)
        guard !search.isEmpty else { return entries.prefix(limit).map { Match(entry: $0, score: 0, highlights: []) } }
        return session.search(query, limit: limit).map { match in
            Match(entry: entries[match.index], score: match.score, highlights: session.index.highlights(search, at: match.index))
        }
    }
}

/// The palette's Files: every file and directory of the active local
/// project, indexed once when the screen opens (`FileIndex.scan`, off the
/// main actor, with `loading` meanwhile) and searched by partial path.
/// Enter opens the pick in a split beside the focused pane (a new tab when
/// the project has none) — a directory as a shell in it, a file in the
/// terminal editor (`TextFileEditor`, as a ⌘-clicked path opens); ⌥↩ opens
/// it with its default app instead.
@MainActor
final class FilesPaletteScope: PaletteScope {
    /// Rows shown at once: the palette draws every row it is given, and a
    /// project has thousands of files.
    static let shownLimit = 50

    let placeholder = "Search files by name or path..."
    private(set) var loading: PaletteLoading?
    private(set) var failure: PaletteFailure?
    private var entries: [FileIndexEntry]?
    private var session: SearchSession?
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
        session = nil
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
            // A detached task doesn't inherit cancellation: hand it on, so
            // closing the palette mid-index stops the walk.
            let indexing = Task.detached(priority: .userInitiated) { () -> ([FileIndexEntry], SearchIndex) in
                let entries = scan(root)
                return (entries, FileIndex.searchIndex(for: entries))
            }
            let (found, index) = await withTaskCancellationHandler {
                await indexing.value
            } onCancel: {
                indexing.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            task = nil
            loading = nil
            entries = found
            session = SearchSession(index: index)
            self.onChange?()
        }
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        self.context = context
        guard let entries, let session, let root, let (project, _) = Self.projectRoot(context) else { return [] }
        let items = FileIndex.matches(entries, session: session, query: query.trimmed, limit: Self.shownLimit).map { match in
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
/// pane — a new tab when it has none — as a shell in the directory or the
/// terminal editor on the file.
@MainActor
enum FilesPaletteActions {
    static func openInSplit(_ url: URL, isDirectory: Bool, project: Project, appState: AppState, projects: [Project]) {
        // A directory URL's path ends in `/`; stored as every project path
        // is, without it (a trailing slash in `$PWD` is fatal to nushell).
        let path = ProjectPath.normalizedForStorage(url.path(percentEncoded: false))
        let command: String? = isDirectory ? nil : TextFileEditor.typedCommand
        let env: [String: String]? = isDirectory ? nil : TextFileEditor.environment(path: path, line: nil)
        let directory = isDirectory ? path : nil
        guard let pane = appState.focusedPane(for: project.id) else {
            if let directory {
                appState.createTab(projectID: project.id, projects: projects, workingDirectory: directory)
            } else {
                appState.createTab(projectID: project.id, projects: projects, command: command, env: env)
            }
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
