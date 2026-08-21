import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "GitClient")

/// Runs `git` for the repository-changes panel. Shelling out rather than
/// linking libgit2: the app already depends on the user's own toolchain being
/// present for everything a terminal does, `git` ships with the Command Line
/// Tools every Mac developer has, and a library would add a build dependency
/// (and its own credential/config story) for what is currently a read-only
/// view. Every call is read-only — nothing here stages, commits, or writes to
/// the repository.
enum GitClient {
    /// Where the panel looks for git. `/usr/bin/git` on macOS is the shim that
    /// resolves through `xcode-select`, so it follows whichever toolchain the
    /// user has active instead of pinning one.
    private static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// A repository as the panel needs to describe it.
    struct Repository: Equatable {
        /// Absolute path of the work tree root — NOT the project directory,
        /// which may sit anywhere beneath it.
        let root: String
        /// Current branch, or nil in a detached HEAD (git answers `HEAD`).
        let branch: String?
    }

    enum Failure: Error, Equatable {
        /// The directory exists but isn't inside a work tree.
        case notARepository
        /// git itself is missing or refused to run.
        case gitUnavailable(String)
    }

    /// Resolve the work tree root and branch for a directory.
    static func repository(at directory: String) async -> Result<Repository, Failure> {
        let root = await run(["rev-parse", "--show-toplevel"], in: directory)
        guard root.status == 0 else {
            // git exits 128 for "not a repository" and for a missing path; the
            // panel shows both as "no repository here", so the distinction
            // only matters in the log.
            logger.debug("repository: not a work tree at \(directory, privacy: .public)")
            return .failure(root.status == 128 ? .notARepository : .gitUnavailable(root.stderr))
        }
        let branch = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        let name = branch.status == 0 ? branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return .success(Repository(
            root: root.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: name.isEmpty || name == "HEAD" ? nil : name
        ))
    }

    /// Every uncommitted change in the work tree, with line counts attached.
    ///
    /// Counts come from two `--numstat` passes (worktree and index) summed per
    /// path, because a file staged AND then edited has changes in both and one
    /// pass would under-report it. Untracked files appear in neither — git has
    /// nothing to diff them against — so they carry no counts rather than a
    /// fabricated zero-diff.
    static func changes(at directory: String) async -> [GitFileChange] {
        let status = await run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: directory
        )
        guard status.status == 0 else { return [] }
        var changes = GitStatusParser.parse(porcelain: status.stdout)

        async let unstaged = run(["diff", "--numstat", "-z"], in: directory)
        async let staged = run(["diff", "--cached", "--numstat", "-z"], in: directory)
        let counts = await GitStatusParser.parseNumstat(unstaged.stdout)
        let stagedCounts = await GitStatusParser.parseNumstat(staged.stdout)

        for index in changes.indices {
            let path = changes[index].path
            let worktree = counts[path] ?? (0, 0)
            let cached = stagedCounts[path] ?? (0, 0)
            changes[index].additions = worktree.additions + cached.additions
            changes[index].deletions = worktree.deletions + cached.deletions
        }
        return changes
    }

    /// The unified diff for one path, as the panel shows it.
    ///
    /// `diff HEAD` rather than a plain `diff`: the panel's subject is "what is
    /// uncommitted", which for a staged-then-edited file is both halves at
    /// once — a plain `diff` would show only the unstaged part and read as if
    /// the staged edit had vanished. An untracked file has no HEAD side at
    /// all, so it goes through `--no-index` against `/dev/null`, which is how
    /// git renders a whole file as additions (and exits 1 by design when the
    /// two differ, hence the status is not checked there).
    static func diff(for change: GitFileChange, at directory: String) async -> String {
        if change.worktree == .untracked {
            let result = await run(
                ["diff", "--no-index", "--no-color", "--", "/dev/null", change.path],
                in: directory
            )
            return result.stdout
        }
        let result = await run(["diff", "HEAD", "--no-color", "--", change.path], in: directory)
        guard result.status == 0 else { return result.stdout.isEmpty ? result.stderr : result.stdout }
        return result.stdout
    }

    // MARK: - Process

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RawOutput {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Read a file's bytes at a revision, or from the working tree when
    /// `revision` is nil. Returns nil rather than empty data when the file
    /// doesn't exist on that side — an image that was just added has no HEAD
    /// version, and a deleted one has no file on disk, and the preview needs
    /// to tell those apart from a zero-byte file.
    ///
    /// `directory` must be the work-tree ROOT: git reports paths relative to
    /// it, not to whatever subdirectory the project happens to point at.
    static func fileData(for path: String, revision: String?, in root: String) async -> Data? {
        guard let revision else {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            return try? Data(contentsOf: url)
        }
        let result = await runRaw(["show", "\(revision):\(path)"], in: root)
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    /// Run one git subcommand and collect its output.
    ///
    /// stdout is drained with `readToEnd()` *while* the child runs, not after
    /// `waitUntilExit()`: a diff easily exceeds the ~64KB pipe buffer, and a
    /// child blocked writing into a full pipe never exits, so the wait-first
    /// shape deadlocks on exactly the large diffs this panel exists to show.
    /// stderr is small by construction (git's error lines) and read after the
    /// fact.
    private static func run(_ arguments: [String], in directory: String) async -> Output {
        let raw = await runRaw(arguments, in: directory)
        return Output(
            status: raw.status,
            stdout: String(decoding: raw.stdout, as: UTF8.self),
            stderr: raw.stderr
        )
    }

    private static func runRaw(_ arguments: [String], in directory: String) async -> RawOutput {
        await withCheckedContinuation { continuation in
            Task.detached {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                // git reads config from the environment; the one thing worth
                // forcing is that it never opens an interactive prompt (a
                // credential helper or pager would hang a read-only call
                // forever with nobody to answer it).
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GIT_PAGER"] = "cat"
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    let verb = arguments.first ?? ""
                    let reason = error.localizedDescription
                    logger.error("git \(verb, privacy: .public) failed to launch: \(reason, privacy: .public)")
                    continuation.resume(returning: RawOutput(status: -1, stdout: Data(), stderr: reason))
                    return
                }

                let out = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                continuation.resume(returning: RawOutput(
                    status: process.terminationStatus,
                    stdout: out,
                    stderr: String(decoding: err, as: UTF8.self)
                ))
            }
        }
    }
}
