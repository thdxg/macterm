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

    /// The user's login shell (`getpwuid`), else `/bin/sh`. Commands start in
    /// it with `-l -c`, by way of `CustomPaletteScript.trampoline`: its rc
    /// files are the only place its PATH lives, and `nu`, `fish`, `zsh` and
    /// `bash` all take that spelling.
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

/// `requires:`, the programs a palette's commands need. Consulted only after
/// a listing fails, so a palette that works pays nothing for declaring them,
/// and one that doesn't says which program is missing instead of showing
/// the shell's own "command not found".
enum CustomPaletteRequirements {
    static let variable = "MACTERM_PALETTE_REQUIRES"

    /// Prints each required program that isn't on PATH, one per line. The
    /// names are split unquoted, which `isProgramName` makes safe: no
    /// whitespace, no glob characters.
    static let probe = #"for c in $MACTERM_PALETTE_REQUIRES; do command -v "$c" >/dev/null 2>&1 || printf "%s\n" "$c"; done"#

    static func isProgramName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-" else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._+-/".unicodeScalars.contains(scalar))
        }
    }

    /// Which of `required` aren't on the PATH the listing ran with, in the
    /// order the file names them; empty when the probe can't tell.
    static func missing(
        _ required: [String],
        environment: [String: String],
        currentDirectory: String?,
        runner: CustomPaletteCommandRunner
    ) async -> [String] {
        guard !required.isEmpty else { return [] }
        let (line, extra) = CustomPaletteScript.invocation(of: probe)
        var env = environment.merging(extra) { _, new in new }
        env[variable] = required.joined(separator: " ")
        guard let result = try? await runner(line, env, currentDirectory), result.status == 0 else { return [] }
        let printed = Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return required.filter(printed.contains)
    }

    /// "This palette needs kubectl and jq, which aren't on your PATH."
    static func message(missing: [String]) -> String {
        let names = switch missing.count {
        case 0,
             1: missing.joined()
        case 2: missing.joined(separator: " and ")
        default: missing.dropLast().joined(separator: ", ") + " and " + (missing.last ?? "")
        }
        let verb = missing.count == 1 ? "isn't" : "aren't"
        return "This palette needs \(names), which \(verb) on your PATH."
    }
}
