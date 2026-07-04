import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectFileStore")

/// Reads and writes the central project-file directory
/// (`~/.config/macterm/projects/`). Stateless: every operation re-scans the
/// directory, so hand-edits made while the app runs are honored without a
/// file watcher (there is none by design — changes surface on next use).
///
/// Matching is always by the `path:` declared *inside* a file (canonicalized
/// via `ProjectPath`), never by filename. When two files declare the same
/// path, the first in byte-lexicographic filename order wins; the duplicate
/// is logged and ignored, never deleted.
@MainActor
struct ProjectFileStore {
    let directoryURL: URL

    init(directoryURL: URL = ProjectFileStore.defaultDirectory()) {
        self.directoryURL = directoryURL
    }

    /// `~/.config/macterm/projects`. Deliberately shared across debug/release
    /// builds — these are user config like the ghostty config, not app state
    /// (App Support splits per build; this doesn't). Resolved through
    /// `NSHomeDirectory()`, which honors `$HOME`, so the benchmark harness's
    /// throwaway home keeps CI runs hermetic.
    nonisolated static func defaultDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/macterm/projects", isDirectory: true)
    }

    // MARK: - Scan / match

    /// A directory entry with its leniently-decoded header. `header` is nil
    /// when the file isn't readable as YAML at all (syntax error / IO error).
    struct ScannedFile {
        let url: URL
        let header: ProjectFileHeader?
    }

    /// All `*.yaml`/`*.yml` entries in byte-lexicographic filename order —
    /// the tie-break order for duplicate `path:` declarations.
    func scan() -> [ScannedFile] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let text = try? String(contentsOf: url, encoding: .utf8)
                return ScannedFile(url: url, header: text.flatMap { ProjectFile.parseHeader(yaml: $0) })
            }
    }

    /// The file declaring `projectPath` (first match wins; later duplicates
    /// are logged). nil when no file declares that path.
    func find(forProjectPath projectPath: String) -> ScannedFile? {
        let matches = scan().filter { file in
            guard let declared = file.header?.path else { return false }
            return ProjectPath.matches(declared, projectPath)
        }
        if matches.count > 1 {
            let ignored = matches.dropFirst().map(\.url.lastPathComponent).joined(separator: ", ")
            let winner = matches[0].url.lastPathComponent
            logger.warning("Duplicate files declare \(projectPath, privacy: .public)")
            logger.warning("Using \(winner, privacy: .public), ignoring \(ignored, privacy: .public)")
        }
        return matches.first
    }

    /// Fully decode the file declaring `projectPath`. nil when no file
    /// matches; throws `LayoutFileError.parse` when one matches but doesn't
    /// decode (surfaced to the user as the apply-error dialog).
    func loadFull(forProjectPath projectPath: String) throws -> ProjectFile? {
        guard let match = find(forProjectPath: projectPath) else { return nil }
        let text: String
        do {
            text = try String(contentsOf: match.url, encoding: .utf8)
        } catch {
            throw LayoutFileError.parse(underlying: error)
        }
        return try ProjectFile.parse(yaml: text)
    }

    /// What "Apply Layout" can do for a project — drives the palette's
    /// muted state.
    enum ApplyState: Equatable {
        /// No file declares this project's path.
        case none
        /// A file matches and declares at least one tab.
        case applicable
        /// A file matches but has no/empty `tabs:` — nothing to apply.
        case emptyTabs
        /// A file matches but fails the full decode. The command stays
        /// enabled so invoking it surfaces the parse error dialog.
        case invalid
    }

    func applyState(forProjectPath projectPath: String) -> ApplyState {
        guard find(forProjectPath: projectPath) != nil else { return .none }
        do {
            guard let file = try loadFull(forProjectPath: projectPath) else { return .none }
            return file.layoutFile == nil ? .emptyTabs : .applicable
        } catch {
            return .invalid
        }
    }

    // MARK: - Write

    /// Write `file` as the declaration for its `path`, named by the slug of
    /// `projectName`. The one mutation path (explicit "Save Layout" / legacy
    /// import) — nothing else in the app writes or deletes project files.
    ///
    /// If a different file already declared this path, it's replaced (its
    /// name may have drifted from the current project name — the filename
    /// realigns to the current slug on save). A slug candidate is "taken"
    /// only when an on-disk file with that name declares a *different* path;
    /// comparison is case-insensitive so case-sensitive APFS volumes behave
    /// like the default case-insensitive ones.
    func write(_ file: ProjectFile, projectName: String) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let existing = scan()
        let bound = existing.first { scanned in
            guard let declared = scanned.header?.path else { return false }
            return ProjectPath.matches(declared, file.path)
        }
        let takenNames = Set(
            existing
                .filter { $0.url != bound?.url }
                .map { $0.url.lastPathComponent.lowercased() }
        )

        let slug = ProjectSlug.slug(from: projectName)
        var attempt = 1
        while takenNames.contains(ProjectSlug.filename(slug: slug, attempt: attempt).lowercased()) {
            attempt += 1
        }
        let target = directoryURL.appendingPathComponent(ProjectSlug.filename(slug: slug, attempt: attempt))

        try file.yaml().write(to: target, atomically: true, encoding: .utf8)
        logger.info("Wrote project file \(target.lastPathComponent, privacy: .public)")

        // Realign: drop the old bound file when the slug moved (rename-by-
        // write-and-delete keeps both steps atomic).
        if let bound, bound.url.lastPathComponent.lowercased() != target.lastPathComponent.lowercased() {
            try? FileManager.default.removeItem(at: bound.url)
            logger.info("Removed superseded project file \(bound.url.lastPathComponent, privacy: .public)")
        }
    }
}
