import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectMemoryStore")

/// The memory of every project: one file for each project,
/// `<App Support>/Memory/<project id>.json`, read when a project is first
/// asked for and written, debounced, after each change.
///
/// Each file is a ring of at most `capacity` entries, oldest first. A file
/// that is present but does not decode is never written over
/// (`loadFailed`), as for `projects.json`: a bad read must not wipe a
/// project's memory at the next command.
@MainActor @Observable
final class ProjectMemoryStore {
    static let capacity = 500
    static let saveDelay = Duration.milliseconds(500)

    /// Entries by project, for the projects read so far.
    private(set) var entries: [UUID: [MemoryEntry]] = [:]
    /// The stored summary of each project read so far.
    private(set) var summaries: [UUID: StoredSummary] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var loadFailed: Set<UUID> = []
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    static let defaultDirectory = FileStorage.appSupportDirectory().appendingPathComponent("Memory", isDirectory: true)

    init(directory: URL = ProjectMemoryStore.defaultDirectory) {
        self.directory = directory
    }

    func fileURL(for projectID: UUID) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json")
    }

    /// The entries read so far, oldest first, with no disk read: what a view
    /// renders. Call `prepare` first, outside the view update.
    func loadedEntries(for projectID: UUID) -> [MemoryEntry] {
        entries[projectID] ?? []
    }

    /// Read a project's file into the cache, once.
    func prepare(_ projectID: UUID) {
        _ = entries(for: projectID)
    }

    /// The project's entries, oldest first, read from disk the first time.
    func entries(for projectID: UUID) -> [MemoryEntry] {
        if let cached = entries[projectID] { return cached }
        let file = load(projectID)
        entries[projectID] = file.entries
        summaries[projectID] = file.summary
        return file.entries
    }

    /// The project's stored summary, read from disk the first time.
    func summary(for projectID: UUID) -> StoredSummary? {
        _ = entries(for: projectID)
        return summaries[projectID]
    }

    func setSummary(_ summary: StoredSummary?, for projectID: UUID) {
        _ = entries(for: projectID)
        summaries[projectID] = summary
        scheduleSave(projectID)
    }

    func append(_ entry: MemoryEntry, to projectID: UUID) {
        var list = entries(for: projectID)
        list.append(entry)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        entries[projectID] = list
        scheduleSave(projectID)
    }

    /// Delete a project's memory, on disk too.
    func forget(_ projectID: UUID) {
        pendingSaves.removeValue(forKey: projectID)?.cancel()
        entries[projectID] = []
        summaries[projectID] = nil
        loadFailed.remove(projectID)
        try? FileManager.default.removeItem(at: fileURL(for: projectID))
    }

    /// Delete every project's memory.
    func forgetAll() {
        for task in pendingSaves.values {
            task.cancel()
        }
        pendingSaves.removeAll()
        loadFailed.removeAll()
        for key in entries.keys {
            entries[key] = []
        }
        summaries.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Delete the files of projects that no longer exist.
    func prune(keeping projectIDs: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !projectIDs.contains(id)
            else { continue }
            forget(id)
        }
    }

    /// Write every pending change now (quit).
    func flush() {
        for projectID in Array(pendingSaves.keys) {
            pendingSaves.removeValue(forKey: projectID)?.cancel()
            save(projectID)
        }
    }

    private func scheduleSave(_ projectID: UUID) {
        pendingSaves[projectID]?.cancel()
        pendingSaves[projectID] = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            pendingSaves[projectID] = nil
            save(projectID)
        }
    }

    private func load(_ projectID: UUID) -> MemoryFile {
        let url = fileURL(for: projectID)
        guard let data = try? Data(contentsOf: url) else { return MemoryFile() }
        do {
            let file = try Self.decoder.decode(MemoryFile.self, from: data)
            guard file.version <= MemoryFile.currentVersion else {
                logger.error("memory of \(projectID, privacy: .public) is a newer version; not writing it")
                loadFailed.insert(projectID)
                return MemoryFile()
            }
            return file
        } catch {
            logger.error("memory of \(projectID, privacy: .public) does not decode: \(EnglishErrorText.describe(error), privacy: .public)")
            loadFailed.insert(projectID)
            return MemoryFile()
        }
    }

    private func save(_ projectID: UUID) {
        guard !loadFailed.contains(projectID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Self.encoder.encode(MemoryFile(entries: entries[projectID] ?? [], summary: summaries[projectID]))
            try data.write(to: fileURL(for: projectID), options: .atomic)
        } catch {
            logger.error("cannot write memory of \(projectID, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
