import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectGit")

/// Reads a local project's git state for the memory panel.
///
/// **Never the `/usr/bin/git` shim on a Mac without the Command Line Tools**:
/// it opens the install dialog (see `GitWorktrees`). `executable` takes a git
/// that is really there: Homebrew's, or the one in the developer directory
/// that `xcode-select -p` names. With none, the panel shows no git state.
///
/// Each run has a timeout, sets `GIT_OPTIONAL_LOCKS=0` so that a read never
/// takes the index lock from the user's own git, and turns the fsmonitor
/// off: a daemon that it starts could hold the output pipe open.
enum ProjectGit {
    static let timeout: Duration = .seconds(5)
    static let recentCommitCount = 5

    /// The git state of the repository at `path`, or nil when it is not in
    /// a repository or no usable git is installed.
    static func status(at path: String) async -> GitStatus? {
        guard let git = resolvedExecutable else { return nil }
        guard let statusOutput = await run(git, ["status", "--porcelain=v2", "--branch", "--show-stash"], in: path) else {
            return nil
        }
        let logOutput = await run(git, ["log", "-\(recentCommitCount)", "--format=%h%x1f%s%x1f%ct"], in: path)
        return GitStatusParser.status(statusOutput: statusOutput, logOutput: logOutput)
    }

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", path, "-c", "core.fsmonitor=false", "--no-pager"] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            logger.error("cannot run git: \(EnglishErrorText.describe(error), privacy: .public)")
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(for: Self.timeout)
            if process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await code in exited.stream {
            status = code
        }
        timeout.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.availableData)
        guard status == 0 else { return nil }
        return String(decoding: collected.data, as: UTF8.self)
    }
}

/// Bytes that a pipe's readability handler collects on its own thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
