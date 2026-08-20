import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "GitBranchNames")

/// The current branch of a directory, for the window's title bar.
///
/// Keyed by DIRECTORY rather than by project, because the question the title
/// bar answers is "what branch is the terminal I'm looking at on" — and a
/// pane's cwd is not always the project root. A `cd` into a submodule, a
/// sibling worktree, or any repository under the project answers differently
/// from the project itself, and keying on the project would report the wrong
/// branch in exactly those cases.
///
/// Deliberately the whole feature: one `git rev-parse`, no status, no counts,
/// no diffs. Reading a branch name is cheap and constant; reading what changed
/// is neither, and the title bar is the wrong place to pay for it.
@MainActor
@Observable
final class GitBranchNames {
    /// Reject a re-read of the same project inside this window. The refresh
    /// hooks are cheap to trigger (every tab switch, every terminal poll
    /// event), and a branch only changes when the user runs a checkout.
    private static let minInterval: TimeInterval = 3

    private var names: [String: String] = [:]
    private var lastReadAt: [String: Date] = [:]
    private var inflight: Set<String> = []

    /// nil when the directory isn't in a repository, sits on a detached HEAD,
    /// or hasn't been read yet — all three mean "show nothing" rather than
    /// something made up.
    func branch(for directory: String) -> String? {
        names[directory]
    }

    /// Read the branch for a directory, unless one is already running for it
    /// or one ran recently.
    func refresh(directory: String, now: Date = Date(), force: Bool = false) {
        guard !directory.isEmpty, !inflight.contains(directory) else { return }
        if !force, let last = lastReadAt[directory], now.timeIntervalSince(last) < Self.minInterval {
            return
        }
        inflight.insert(directory)
        lastReadAt[directory] = now
        Task {
            let name = await Self.readBranch(in: directory)
            inflight.remove(directory)
            // Assign rather than skip on nil: a directory that stopped being a
            // repository (or moved to a detached HEAD) must lose its old
            // branch, not keep showing a name that no longer applies.
            names[directory] = name
        }
    }

    /// Parse `git rev-parse --abbrev-ref HEAD`. A detached HEAD answers the
    /// literal string `HEAD`, which is not a branch name and must not be shown
    /// as one.
    nonisolated static func parseBranch(_ stdout: String) -> String? {
        let name = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    nonisolated private static func readBranch(in directory: String) async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                // A read this small must never park on a prompt: a credential
                // helper or pager would hold the subprocess open with nobody
                // watching it.
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GIT_PAGER"] = "cat"
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    logger.debug("git rev-parse failed to launch: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    // Not a repository (128) is the ordinary case, not an error
                    // worth surfacing — plenty of projects aren't repositories.
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: parseBranch(String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
