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
    /// it as a login shell (`CustomPaletteLaunch.loginFlags`), by way of
    /// `CustomPaletteScript.trampoline`: its rc files are the only place its
    /// PATH lives.
    nonisolated static var loginShell: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }), !shell.isEmpty {
            return shell
        }
        return "/bin/sh"
    }

    /// `command` in the login shell, with `environment` laid over the app's
    /// own (which carries `MACTERM_SOCKET` and the bundled CLI on PATH, like
    /// every pane's).
    static let run: CustomPaletteCommandRunner = runner(timeout: timeout)

    /// A `when:` check gives up sooner than a listing: the row it decides
    /// is already on screen.
    static let conditionTimeout: Duration = .seconds(10)
    static let checkCondition: CustomPaletteCommandRunner = runner(timeout: conditionTimeout)

    /// The runner, giving up after `timeout` (a test's is short).
    ///
    /// The command runs in a process group of its own, and a timeout — or
    /// the listing's task being cancelled, as closing the palette does —
    /// signals the whole group: SIGTERM to the login shell alone left `sleep`,
    /// `kubectl` and every stage of a pipeline running with the output pipe
    /// open, so the screen sat on "Listing…" until they finished on their
    /// own. The pipes are read on threads of their own, not Swift's
    /// cooperative pool, and a timeout doesn't wait for them.
    static func runner(timeout: Duration) -> CustomPaletteCommandRunner {
        { command, environment, currentDirectory in
            let shell = loginShell
            let child = try SpawnedCommand(
                argv: [shell] + CustomPaletteLaunch.loginFlags(forShell: shell) + [command],
                environment: ProcessInfo.processInfo.environment.merging(environment) { _, override in override },
                currentDirectory: currentDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            )
            let output = Task { await child.drain(child.stdout) }
            let errors = Task { await child.drain(child.stderr) }
            let status: Int32 = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await child.exitStatus() }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        // Cancelled: the command finished first (the
                        // group cancels this task), or the listing's task
                        // was cancelled. Only the second leaves it running.
                        child.terminateGroup()
                        throw error
                    }
                    child.terminateGroup()
                    throw TimedOut()
                }
                defer { group.cancelAll() }
                return try await group.next() ?? 0
            }
            return await CustomPaletteCommandResult(stdout: output.value, stderr: errors.value, status: status)
        }
    }
}

/// One spawned command: its own process group, its output pipes, and the
/// one-time wait for it to end. Signals go to the group only until the
/// process has exited — the exit is seen without reaping it (`WNOWAIT`), so
/// the group id can't have been handed to an unrelated process yet.
private final class SpawnedCommand: @unchecked Sendable {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32
    private let lock = NSLock()
    private var exited = false

    init(argv: [String], environment: [String: String], currentDirectory: String?) throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group (to signal as one), default dispositions for
        // what the app may ignore or handle (a pipeline's SIGPIPE must kill),
        // nothing blocked, and none of the app's other descriptors.
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGTTIN, SIGTTOU, SIGTSTP] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { (cargs + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, argv[0], &actions, &attributes, cargs, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard spawned == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw POSIXError(.init(rawValue: spawned) ?? .EIO)
        }
        self.pid = pid
        stdout = outPipe[0]
        stderr = errPipe[0]
    }

    /// Everything `fd` delivers until end of file, read off the cooperative
    /// pool; closes `fd`.
    func drain(_ fd: Int32) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        data.append(buffer, count: count)
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// The exit status — a signal's as 128 + its number, as a shell says
    /// it — once the process has ended, which it then reaps. Whatever the
    /// command left running in its group (`sleep 100 &`) is ended first,
    /// while the unreaped leader still holds the group's id: it would keep
    /// the output pipe open, and a listing ends when its command does.
    func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                lock.withLock { exited = true }
                killpg(pid, SIGTERM)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                let signal = status & 0x7F
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xFF : 128 + signal)
            }
        }
    }

    /// SIGTERM to the whole group, SIGKILL a second later to whatever is
    /// left; nothing once the process has exited.
    func terminateGroup() {
        guard lock.withLock({ !exited }) else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            guard lock.withLock({ !exited }) else { return }
            killpg(pid, SIGKILL)
        }
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
        let verb = missing.count == 1 ? "is not" : "are not"
        return "This palette needs \(names), which \(verb) on your PATH."
    }
}

/// Runs `when:` checks (`CustomPaletteCondition`): each distinct command
/// once, concurrently, the way a listing runs — through the login shell into
/// `sh` or a `#!` interpreter, in `environment` and `currentDirectory`.
/// Exit 0 is available; anything else — a non-zero exit, a timeout, a
/// command that won't start — is not.
enum CustomPaletteConditions {
    static func evaluate(
        _ commands: Set<String>,
        environment: [String: String],
        currentDirectory: String?,
        runner: @escaping CustomPaletteCommandRunner
    ) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { group in
            for command in commands {
                group.addTask {
                    let invocation = CustomPaletteScript.invocation(of: command)
                    let env = environment.merging(invocation.environment) { _, new in new }
                    let status = try? await runner(invocation.line, env, currentDirectory).status
                    return (command, status == 0)
                }
            }
            var verdicts: [String: Bool] = [:]
            for await (command, ok) in group {
                verdicts[command] = ok
            }
            return verdicts
        }
    }
}
