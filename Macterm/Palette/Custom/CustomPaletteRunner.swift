import Foundation

/// What a palette command printed and how it ended.
struct CustomPaletteCommandResult: Equatable {
    let stdout: String
    let stderr: String
    let status: Int32
}

/// Runs a palette's commands. A closure so a test's scope lists from canned
/// output; the real one is `CustomPaletteRunner.run`.
typealias CustomPaletteCommandRunner = @Sendable (
    _ command: String,
    _ environment: [String: String],
    _ currentDirectory: String?
) async throws -> CustomPaletteCommandResult

enum CustomPaletteRunner {
    /// A listing that hasn't printed by then is given up on, so a hung
    /// `kubectl` doesn't leave the screen loading forever.
    static let timeout: Duration = .seconds(30)

    struct TimedOut: Error {}

    /// The user's login shell (`getpwuid`), else `/bin/sh`. Commands run in
    /// it with `-l -c`: it is what the user writes commands for, its rc files
    /// are the only place its PATH lives, and `nu`, `fish`, `zsh` and `bash`
    /// all take that spelling.
    nonisolated static var loginShell: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }), !shell.isEmpty {
            return shell
        }
        return "/bin/sh"
    }

    /// `command` in the login shell, with `environment` laid over the app's
    /// own (which carries `MACTERM_SOCKET` and the bundled CLI on PATH, like
    /// every pane's).
    static let run: CustomPaletteCommandRunner = { command, environment, currentDirectory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-l", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        if let currentDirectory, FileManager.default.fileExists(atPath: currentDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Both pipes drained concurrently: a command that fills one while
        // we wait on the other deadlocks.
        async let out = Self.readAll(stdout.fileHandleForReading)
        async let err = Self.readAll(stderr.fileHandleForReading)
        let status: Int32 = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    if !process.isRunning { continuation.resume() }
                }
                return process.terminationStatus
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            do {
                return try await group.next() ?? 0
            } catch {
                process.terminate()
                throw error
            }
        }
        return await CustomPaletteCommandResult(stdout: out, stderr: err, status: status)
    }

    private static func readAll(_ handle: FileHandle) async -> String {
        await Task.detached {
            String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }
}

/// The environment every palette command runs in, above the app's own:
/// where the user is, so a command can read context without any templating,
/// plus what the rows above exported.
enum CustomPaletteEnvironment {
    static let projectDirectoryKey = "MACTERM_PROJECT_DIR"
    static let projectNameKey = "MACTERM_PROJECT_NAME"

    static func make(projectName: String?, projectDirectory: String?, exports: [String: String]) -> [String: String] {
        var env = exports
        if let projectName { env[projectNameKey] = projectName }
        if let projectDirectory { env[projectDirectoryKey] = projectDirectory }
        return env
    }
}
