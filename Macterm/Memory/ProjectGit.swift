import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectGit")

/// Reads a project's git state for the memory panel: locally, or over ssh
/// for a remote project (`remoteStatus`).
///
/// **Never the `/usr/bin/git` shim on a Mac without the Command Line Tools**:
/// it opens the install dialog (see `GitWorktrees`). `executable` takes a git
/// that is really there: Homebrew's, or the one in the developer directory
/// that `xcode-select -p` names. With none, the panel shows no git state.
///
/// Each run has a timeout, sets `GIT_OPTIONAL_LOCKS=0` so that a read never
/// takes the index lock from the user's own git, and turns the fsmonitor
/// off: a daemon that it starts could hold the output pipe open.
///
/// A remote read is one ssh connection that runs the same four commands on
/// the host (`RemoteSpawn.gitProbeArgv`), with the outputs separated by
/// `recordSeparator`. It is a background connection like the foreground
/// probe, so `Preferences.backgroundSSHConnections` gates it (#272), and a
/// host that refuses the login is not asked again in this run
/// (`RemoteResult.authRefused`, applied by `ProjectMemory`).
enum ProjectGit {
    static let timeout: Duration = .seconds(5)
    /// A remote read waits for the connection too (`opConnectTimeoutSeconds`).
    static let remoteTimeout: Duration = .seconds(15)
    /// How long after git exits its output is still read.
    static let drainTimeout: Duration = .seconds(1)
    static let recentCommitCount = 5
    static let recentBranchCount = 6
    /// Between the four outputs of a remote read (ASCII record separator).
    static let recordSeparator: Character = "\u{1E}"

    /// The git state of the repository at `path`, or nil when it is not in
    /// a repository or no usable git is installed.
    static func status(at path: String) async -> GitStatus? {
        guard let git = resolvedExecutable else { return nil }
        guard let statusOutput = await run(git, ["status", "--porcelain=v2", "--branch", "--show-stash"], in: path) else {
            return nil
        }
        let logOutput = await run(git, ["log", "-\(recentCommitCount)", "--format=%h%x1f%s%x1f%ct"], in: path)
        let branchesOutput = await run(git, [
            "for-each-ref", "refs/heads", "--sort=-committerdate", "--count=\(recentBranchCount)",
            "--format=%(refname:short)\u{1F}%(objectname:short)\u{1F}%(committerdate:unix)\u{1F}%(subject)",
        ], in: path)
        let worktreesOutput = await run(git, ["worktree", "list", "--porcelain"], in: path)
        return GitStatusParser.status(
            statusOutput: statusOutput,
            logOutput: logOutput,
            branchesOutput: branchesOutput,
            worktreesOutput: worktreesOutput
        )
    }

    // MARK: - Remote

    /// What one remote read found.
    enum RemoteResult: Equatable {
        /// The host answered: its git state, or nil when the directory is
        /// not in a repository or the host has no git.
        case read(GitStatus?)
        /// No answer: the host is not reachable, or the read timed out.
        /// What is known stays.
        case unreachable
        /// The host refused the non-interactive login (#272). Under
        /// `BatchMode` a refusal can only repeat, and on a Touch ID key
        /// every attempt is a dialog, so the host is not asked again.
        case authRefused
    }

    /// The git state of a remote project's directory, over one ssh
    /// connection. The ssh is the one on PATH, through `/usr/bin/env`, as
    /// every background operation (see `ZmxClient.live`).
    static func remoteStatus(_ remote: ProjectPath) async -> RemoteResult {
        guard let argv = RemoteSpawn.gitProbeArgv(remote: remote) else { return .unreachable }
        guard let outcome = await runProcess(
            "/usr/bin/env", ["ssh"] + argv, environment: ProcessInfo.processInfo.environment, timeout: remoteTimeout
        )
        else {
            return .unreachable
        }
        switch outcome.status {
        case 0:
            return .read(parseRemoteOutput(outcome.stdout))
        case 2,
             3,
             4:
            // The script's own exits: no such directory, no git, not a repository.
            return .read(nil)
        case 255:
            return RemoteProbeOutcome.classifyFailure(stderr: outcome.stderr) == .authRefused ? .authRefused : .unreachable
        default:
            return .unreachable
        }
    }

    /// The four outputs of `RemoteSpawn.gitProbeArgv`, split at the record
    /// separator, through `GitStatusParser`. A reply with fewer parts has
    /// the rest as nil.
    static func parseRemoteOutput(_ output: String) -> GitStatus? {
        let parts = output.split(separator: recordSeparator, omittingEmptySubsequences: false).map(String.init)
        // An empty status is no repository, whatever the exit code was.
        guard let statusOutput = parts.first, !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return GitStatusParser.status(
            statusOutput: statusOutput,
            logOutput: parts.count > 1 ? parts[1] : nil,
            branchesOutput: parts.count > 2 ? parts[2] : nil,
            worktreesOutput: parts.count > 3 ? parts[3] : nil
        )
    }

    // MARK: - Local git

    /// `executable()`, found once for each run of the app.
    static let resolvedExecutable: String? = executable()

    /// A git that runs without the install dialog, or nil.
    static func executable(fileManager: FileManager = .default) -> String? {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        guard let developerDirectory = developerDirectory() else { return nil }
        let git = (developerDirectory as NSString).appendingPathComponent("usr/bin/git")
        return fileManager.isExecutableFile(atPath: git) ? git : nil
    }

    /// `xcode-select -p`, which prints the developer directory and never
    /// opens a dialog. nil when none is selected.
    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// stdout of `git -C path args`, or nil on a failure or a timeout.
    private static func run(_ git: String, _ args: [String], in path: String) async -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let outcome = await runProcess(
            git, ["-C", path, "-c", "core.fsmonitor=false", "--no-pager"] + args, environment: environment, timeout: timeout
        ), outcome.status == 0
        else { return nil }
        return outcome.stdout
    }

    // MARK: - Process

    struct Outcome {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a process to its exit, bounded by `timeout`, and collect both
    /// streams. nil when it cannot start.
    ///
    /// Each pipe is read as data arrives, never with `readDataToEndOfFile`:
    /// the handler reports EOF with no data once the child's end closes,
    /// and every byte the child wrote is collected by then. The wait for
    /// EOF after the exit is bounded by `drainTimeout`, because a child of
    /// the process (a daemon git starts, a child of ssh) could keep a pipe
    /// open after the process exited.
    private static func runProcess(
        _ executable: String, _ arguments: [String], environment: [String: String], timeout: Duration
    ) async -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = CollectedPipe()
        let stderr = CollectedPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            stdout.stop()
            stderr.stop()
            logger.error("cannot run \(executable, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            return nil
        }
        let killer = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await code in exited.stream {
            status = code
        }
        killer.cancel()
        await stdout.finish(within: drainTimeout)
        await stderr.finish(within: drainTimeout)
        return Outcome(status: status, stdout: stdout.text, stderr: stderr.text)
    }
}

/// A pipe whose readability handler collects the bytes on its own thread
/// and reports EOF.
private final class CollectedPipe: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var storage = Data()
    private let eof = AsyncStream<Void>.makeStream()

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.eof.continuation.finish()
            } else {
                self?.append(data)
            }
        }
    }

    private func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    /// Wait for EOF, at most `limit`, then stop reading.
    func finish(within limit: Duration) async {
        let drain = Task { [eof] in
            try? await Task.sleep(for: limit)
            eof.continuation.finish()
        }
        for await _ in eof.stream {}
        drain.cancel()
        stop()
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}
