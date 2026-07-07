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
    /// (App Support splits per build; this doesn't). Resolved `$HOME`-first:
    /// `NSHomeDirectory()` resolves via the user record and IGNORES the env
    /// var (verified empirically), which would defeat the benchmark harness's
    /// throwaway-home isolation. The login session sets `$HOME` for normal
    /// launches, so env-first behaves identically outside the harness.
    nonisolated static func defaultDirectory() -> URL {
        URL(fileURLWithPath: ProjectPath.currentHome, isDirectory: true)
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

    /// Every file declaring `projectPath`, in filename order — the first is
    /// the one `find`/`loadFull` use; the rest are ignored duplicates the UI
    /// surfaces (a hand-authored copy, or a realign-delete that failed).
    func matches(forProjectPath projectPath: String) -> [ScannedFile] {
        matches(forProjectPath: projectPath, in: scan())
    }

    private func matches(forProjectPath projectPath: String, in scanned: [ScannedFile]) -> [ScannedFile] {
        scanned.filter { file in
            guard let declared = file.header?.path else { return false }
            return ProjectPath.matches(declared, projectPath)
        }
    }

    /// The file declaring `projectPath` (first match wins; later duplicates
    /// are logged). nil when no file declares that path.
    func find(forProjectPath projectPath: String) -> ScannedFile? {
        find(forProjectPath: projectPath, in: scan())
    }

    private func find(forProjectPath projectPath: String, in scanned: [ScannedFile]) -> ScannedFile? {
        let found = matches(forProjectPath: projectPath, in: scanned)
        if found.count > 1 {
            let ignored = found.dropFirst().map(\.url.lastPathComponent).joined(separator: ", ")
            let winner = found[0].url.lastPathComponent
            logger.warning("Duplicate files declare \(projectPath, privacy: .public)")
            logger.warning("Using \(winner, privacy: .public), ignoring \(ignored, privacy: .public)")
        }
        return found.first
    }

    /// Fully decode the file declaring `projectPath`. nil when no file
    /// matches; throws `LayoutFileError.parse` when one matches but doesn't
    /// decode (surfaced to the user as the apply-error dialog).
    func loadFull(forProjectPath projectPath: String) throws -> ProjectFile? {
        try loadFull(forProjectPath: projectPath, in: scan())
    }

    private func loadFull(forProjectPath projectPath: String, in scanned: [ScannedFile]) throws -> ProjectFile? {
        guard let match = find(forProjectPath: projectPath, in: scanned) else { return nil }
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
        // Scan the directory ONCE and thread it through find + loadFull, rather
        // than re-scanning (and re-parsing every file's header) three times
        // within this single operation. Statelessness across DISTINCT
        // operations is intentional; the intra-operation rescans were waste.
        let scanned = scan()
        guard find(forProjectPath: projectPath, in: scanned) != nil else { return .none }
        do {
            guard let file = try loadFull(forProjectPath: projectPath, in: scanned) else { return .none }
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
    ///
    /// A local `path` has its home prefix contracted to `~` on the way out:
    /// these files are dotfile-syncable user config, and a hardcoded
    /// `/Users/<name>/…` breaks on the next machine. Returns the written URL
    /// so callers can tell whether their file is the one `find` will pick.
    @discardableResult
    func write(_ file: ProjectFile, projectName: String) throws -> URL {
        var file = file
        if case .local = ProjectPath.parse(file.path) {
            file.path = ProjectPath.homeContracted(file.path)
        }
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

        // Pick the target filename. When a file already declares this path,
        // compute the fresh slug candidate; if it names the SAME file the bound
        // one already occupies (case-insensitively — the default APFS behavior),
        // rewrite that exact file in place, preserving its on-disk casing. This
        // avoids the case-sensitive-volume hazard where writing `api.yaml`
        // beside a hand-named `API.yaml` leaves two files declaring one path and
        // byte-order lets the stale `API.yaml` win.
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
        let candidate = directoryURL.appendingPathComponent(ProjectSlug.filename(slug: slug, attempt: attempt))

        let target: URL = if let bound, bound.url.lastPathComponent.lowercased() == candidate.lastPathComponent.lowercased() {
            // Same file up to case — rewrite in place at its existing name so we
            // don't create a case-variant twin on a case-sensitive volume.
            bound.url
        } else {
            candidate
        }

        try file.yaml().write(to: target, atomically: true, encoding: .utf8)
        logger.info("Wrote project file \(target.lastPathComponent, privacy: .public)")

        // Realign: drop the old bound file when the slug genuinely moved to a
        // different name (rename-by-write-and-delete keeps both steps atomic).
        // Guarded by `bound.url != target` so we never delete the file we just
        // rewrote in place.
        if let bound, bound.url != target {
            do {
                try FileManager.default.removeItem(at: bound.url)
                logger.info("Removed superseded project file \(bound.url.lastPathComponent, privacy: .public)")
            } catch {
                // The save itself succeeded; the leftover is now a duplicate
                // declaration the caller surfaces via `matches`.
                logger.error("Couldn't remove superseded \(bound.url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        return target
    }
}
