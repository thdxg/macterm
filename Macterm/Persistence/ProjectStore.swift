import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    /// `projects.json`: the projects with a folder.
    private let fileURL: URL
    /// The projects without a folder, in a file of their own beside
    /// `fileURL`. Builds from before them decode `path` as a required key,
    /// so ONE row with no path in `projects.json` makes such a build read no
    /// projects at all — and its restore then drops every workspace and
    /// reaps every session. Here, an older build reads the projects that it
    /// can express and never sees the rest.
    private let folderlessFileURL: URL
    /// Set when `load()` found a present-but-undecodable file. While set,
    /// `save()` refuses to overwrite either file — a transient read/decode
    /// failure must never let the next mutation wipe the user's project list.
    /// The launch restore reads it too (`AppState.restoreSelection`): with
    /// the list unknown, no snapshot or session can be judged an orphan.
    @ObservationIgnored
    private(set) var loadFailed = false
    /// Whether `create` tags a new project. Injectable so tests don't mutate
    /// the shared preference — swift-testing runs suites in parallel.
    @ObservationIgnored
    var autoAssignsColors: () -> Bool = { Preferences.shared.autoAssignProjectColors }

    init(fileURL: URL = FileStorage.fileURL(filename: "projects.json")) {
        self.fileURL = fileURL
        folderlessFileURL = Self.folderlessFileURL(beside: fileURL)
        load()
    }

    /// `projects.json` → `projects_folderless.json`, in the same directory.
    /// Derived from the main file, so a test's own file gets its own sibling.
    static func folderlessFileURL(beside fileURL: URL) -> URL {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(stem)_folderless.json")
    }

    func project(matchingPath path: String) -> Project? {
        projects.first { ProjectPath.matches($0.path, path) }
    }

    /// Return the first project whose path matches, else add a new one. The
    /// create-or-select entry point for idempotent callers — the benchmark
    /// harness (which may replay `open-project`) and any script that expects
    /// re-running to be a no-op. Interactive project creation goes through
    /// `create` instead, so the same directory can back several projects.
    @discardableResult
    func findOrCreate(name: String, path: String, zmxPath: String? = nil) -> Project {
        if let existing = project(matchingPath: path) {
            return existing
        }
        return create(name: name, path: path, zmxPath: zmxPath)
    }

    /// Always add a new project, even when one already backs this directory.
    /// A directory is not an identity: two projects may share a `path` and
    /// keep wholly independent workspaces (keyed on `Project.id`) and zmx
    /// sessions (named with per-pane entropy). This is the entry point for
    /// user-initiated creation (folder picker, remote sheet, `project create`).
    ///
    /// A name the pinned workspace reserves is stored suffixed (see
    /// `unreservedName`). Most callers pass the folder's own name — the
    /// picker, Finder, Open With, the palette, a bare `project create` — which
    /// nobody chose, so refusing it would make a folder called Pinned
    /// impossible to add. A caller holding a name someone typed refuses it
    /// before calling this, where it can say why.
    @discardableResult
    func create(name: String, path: String? = nil, zmxPath: String? = nil) -> Project {
        insert(Project(name: Self.unreservedName(name), path: path, zmxPath: zmxPath))
    }

    func add(_ project: Project) {
        var project = project
        project.path = project.path.map(ProjectPath.normalizedForStorage)
        projects.append(project)
        save()
    }

    /// Import a folderless layout without changing its identity. Repeated
    /// imports select the same project so its saved layout stays unambiguous.
    /// nil when `canImportFolderless` refuses the ID.
    func importFolderless(name: String, id: UUID) -> Project? {
        guard canImportFolderless(id: id) else { return nil }
        if let existing = projects.first(where: { $0.id == id }) { return existing }
        return insert(Project(id: id, name: Self.unreservedName(name), path: nil))
    }

    /// Whether `importFolderless` accepts `id`. It refuses the pinned
    /// workspace's ID and the ID of a project with a folder: a layout that
    /// declares either can never belong to a project without a folder.
    func canImportFolderless(id: UUID) -> Bool {
        guard id != PinnedTabs.projectID else { return false }
        guard let existing = projects.first(where: { $0.id == id }) else { return true }
        return existing.path == nil
    }

    /// Append a new project at the end of the list, tagged when the
    /// preference says so. Every new project goes through here.
    private func insert(_ project: Project) -> Project {
        var project = project
        project.sortOrder = projects.count
        if autoAssignsColors() {
            project.colorName = ProjectColor.leastUsed(among: projects.map(\.color)).rawValue
        }
        add(project)
        return project
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    /// Rename a project, unless `PinnedTabs.reservesName` matches the new
    /// name: then the project keeps its old one. Every caller holds a name
    /// someone typed and says why first (the CLI's `bad_request`, the
    /// sidebar's notice); this only stops one that forgot to.
    func rename(id: UUID, to newName: String) {
        guard !PinnedTabs.reservesName(newName) else {
            logger.error("Refusing to rename project \(id, privacy: .public) to reserved name \(newName, privacy: .public)")
            return
        }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = newName
        save()
    }

    /// `name`, or — when the pinned workspace reserves it — the name a second
    /// one would get: `Pinned 2`, the suffix its layout file already takes
    /// (`pinned_2.yaml`, see `ProjectFileStore.write`). The case is kept; it
    /// is still the folder's name. Only the bare name is reserved, so the
    /// suffixed one is always reachable, and a second project from the same
    /// folder is a second `Pinned 2`, as a second `api` is a second `api`.
    private static func unreservedName(_ name: String) -> String {
        guard PinnedTabs.reservesName(name) else { return name }
        let suffixed = "\(name.trimmingCharacters(in: .whitespacesAndNewlines)) 2"
        logger.info("Project name \(name, privacy: .public) is reserved; creating \(suffixed, privacy: .public)")
        return suffixed
    }

    /// Set (or clear, with nil) the project's color tag.
    func setColor(id: UUID, to color: ProjectColor?) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard projects[index].colorName != color?.rawValue else { return }
        projects[index].colorName = color?.rawValue
        save()
    }

    func setPath(id: UUID, to newPath: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ProjectPath.normalizedForStorage(newPath)
        guard projects[index].path != normalized else { return }
        projects[index].path = normalized
        save()
    }

    func reorder(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        for i in projects.indices {
            projects[i].sortOrder = i
        }
        save()
    }

    /// Write both files. The file without folders goes first: if the second
    /// write fails, a project that moved between them is in both files, and
    /// `load` keeps one copy. In the other order it would be in neither.
    private func save() {
        guard !loadFailed else {
            logger.error("Refusing to save projects: prior load failed, file preserved")
            return
        }
        let folderless = projects.filter { $0.path == nil }
        do {
            // No file until the first project without a folder exists.
            if !folderless.isEmpty || FileManager.default.fileExists(atPath: folderlessFileURL.path) {
                try Self.encode(folderless).write(to: folderlessFileURL, options: .atomic)
            }
            try Self.encode(projects.filter { $0.path != nil }).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save projects: \(error, privacy: .public)")
        }
    }

    private static func encode(_ projects: [Project]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(projects)
    }

    private func load() {
        // `projects.json` decodes a row with no path too: a build of this
        // feature before the split wrote them there. The next save moves them.
        let loaded = (read(fileURL) ?? []) + (read(folderlessFileURL) ?? [])
        var seen = Set<UUID>()
        projects = loaded.filter { seen.insert($0.id).inserted }
        projects.sort { $0.sortOrder < $1.sortOrder }
        // Migrate paths stored before normalization existed (e.g. with the
        // trailing slash `URL.path(percentEncoded:)` keeps on directories).
        // In-memory only; the cleaned form persists on the next mutation.
        for i in projects.indices {
            projects[i].path = projects[i].path.map(ProjectPath.normalizedForStorage)
        }
    }

    /// The projects in one file. nil for an absent or empty file (a genuine
    /// empty state) and for one that fails, which also sets `loadFailed`.
    private func read(_ url: URL) -> [Project]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            loadFailed = true
            return nil
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode([Project].self, from: data)
        } catch {
            // Present but undecodable — a corrupt entry or a future format.
            // Preserve the file: refuse to overwrite it until this session
            // restarts and reads it cleanly (or the user fixes it).
            logger.error("Failed to decode \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            loadFailed = true
            return nil
        }
    }
}
