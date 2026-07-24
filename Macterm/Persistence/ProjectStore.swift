import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private let fileURL: URL
    /// Set when `load()` found a present-but-undecodable projects.json. While
    /// set, `save()` refuses to overwrite — a transient read/decode failure
    /// must never let the next mutation wipe the user's entire project list.
    @ObservationIgnored
    private var loadFailed = false

    init(fileURL: URL = FileStorage.fileURL(filename: "projects.json")) {
        self.fileURL = fileURL
        load()
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
    @discardableResult
    func create(name: String, path: String, zmxPath: String? = nil) -> Project {
        let project = Project(name: name, path: path, sortOrder: projects.count, zmxPath: zmxPath)
        add(project)
        return project
    }

    func add(_ project: Project) {
        var project = project
        project.path = ProjectPath.normalizedForStorage(project.path)
        projects.append(project)
        save()
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = newName
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

    private func save() {
        guard !loadFailed else {
            logger.error("Refusing to save projects: prior load failed, file preserved")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save projects: \(error, privacy: .public)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.error("Failed to read projects file: \(error, privacy: .public)")
            loadFailed = true
            return
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
            projects.sort { $0.sortOrder < $1.sortOrder }
            // Migrate paths stored before normalization existed (e.g. with the
            // trailing slash `URL.path(percentEncoded:)` keeps on directories).
            // In-memory only; the cleaned form persists on the next mutation.
            for i in projects.indices {
                projects[i].path = ProjectPath.normalizedForStorage(projects[i].path)
            }
        } catch {
            // Present but undecodable — a corrupt entry or a future format.
            // Preserve the file: refuse to overwrite it until this session
            // restarts and reads it cleanly (or the user fixes it).
            logger.error("Failed to decode projects file: \(error, privacy: .public)")
            loadFailed = true
        }
    }
}
