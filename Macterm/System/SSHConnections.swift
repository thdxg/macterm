import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "SSHConnections")

/// One ssh connection for each host (design/005, step 1). Every command to a
/// host goes over that connection, so the user logs in once for each host,
/// as with `ssh host` in a terminal.
///
/// - If the user's own ssh config names a ControlPath (`ssh -G`) and a master
///   answers there (`ssh -O check`), Macterm uses it and opens no master.
/// - Otherwise Macterm runs `ssh -M -N` with its own ControlPath in
///   `<App Support>/cm/`. Its prompts go to `macterm askpass`
///   (`SSH_ASKPASS_REQUIRE=force`), which asks the GUI (`SSHLoginPrompts`).
///   The GUI answers only the bundled askpass, started under one of these
///   masters (`askpassOwner(forPeer:)`, design/006 §4).
/// - A command over the master (`run`) never logs in by itself: `BatchMode`
///   refuses a prompt, and `ProxyCommand=/usr/bin/false` stops the direct
///   connection that ssh tries when the master does not answer. It fails
///   closed.
///
/// - A login that writes text and asks nothing for `SSHLoginNotice.delay`
///   (a host that waits for a log-in in the browser) reports ssh's last
///   line to `onLoginNotice`, until the login ends or a question comes.
///
/// Each new login writes a log line with the count for its host in this run
/// (`ssh login: host=… logins=…`), so that the logins of a day can be
/// counted from the log (design/005, the roaming-link question).
@MainActor
final class SSHConnections {
    struct Configuration {
        /// The ssh of PATH, through `/usr/bin/env`, as every background
        /// operation of a remote project.
        var ssh: [String] = ["/usr/bin/env", "ssh"]
        /// Options in front of every other argument. Tests give `-F <config>`.
        var options: [String] = []
        /// Where Macterm's own ControlPaths go. Mode 0700.
        var controlDirectory: URL
        /// The `SSH_ASKPASS` program of a master. nil: ssh's own default.
        var askpass: String?
        /// More environment for a master (the socket that askpass reports to).
        var environment: [String: String] = [:]
        /// The executable that a peer of `ssh.askpass` must be. nil: any.
        var askpassExecutable: String?

        static var live: Configuration {
            Configuration(
                controlDirectory: FileStorage.appSupportDirectory().appendingPathComponent("cm", isDirectory: true),
                askpass: Bundle.main.resourceURL?.appendingPathComponent("ssh-bridge/macterm-askpass").path,
                environment: [SSHConnections.askpassSocketVariable: ControlSocketServer.defaultSocketPath()],
                // The shim execs the bundled CLI, so the peer runs it.
                askpassExecutable: Bundle.main.resourceURL?.appendingPathComponent("bin/macterm").resolvingSymlinksInPath().path
            )
        }
    }

    /// Tells `macterm askpass` which app to ask: the one that started its ssh.
    nonisolated static let askpassSocketVariable = "MACTERM_ASKPASS_SOCKET"

    /// How a host is reached.
    struct Route: Equatable {
        var controlPath: String
        /// The user's own ControlMaster, which Macterm never ends.
        var isUsersOwn: Bool
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidDestination(String)
        case controlPathTooLong(String)
        case cannotStart(String)
        /// The master exited before it listened: a refused login, a
        /// failed prompt, or no route to the host. ssh's last line of
        /// stderr.
        case loginFailed(String)
        /// The user cancelled a question of the login.
        case cancelled

        var description: String {
            switch self {
            case let .invalidDestination(destination): "not an ssh destination: \(destination)"
            case let .controlPathTooLong(path): "the control path is too long for a socket: \(path)"
            case let .cannotStart(reason): "cannot start ssh: \(reason)"
            case let .loginFailed(reason): reason.isEmpty ? "the ssh login failed" : "the ssh login failed: \(reason)"
            case .cancelled: "the ssh login was cancelled"
            }
        }
    }

    static let shared = SSHConnections(configuration: .live)

    private let configuration: Configuration
    private var routes: [String: Route] = [:]
    /// Macterm's own master for each host.
    private var owned: [String: Process] = [:]
    private var connecting: [String: Task<Route, Error>] = [:]
    /// Masters whose login the user cancelled.
    private var cancelled: Set<pid_t> = []
    /// New logins for each host in this run.
    private(set) var logins: [String: Int] = [:]
    /// Called when a master exits, with its pid, so that a prompt of its
    /// askpass that is still up goes away.
    var onConnectionExit: ((pid_t) -> Void)?
    /// Called with ssh's last line while a login waits with no question,
    /// and with nil when that ends (`SSHLoginNotice`).
    var onLoginNotice: ((_ host: String, _ pid: pid_t, _ line: String?) -> Void)?
    /// Questions that are open for each master.
    private var asking: [pid_t: Int] = [:]

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The route to `destination`, after the login if there is none yet.
    /// Calls for one host at the same time share one login.
    func connect(_ destination: String) async throws -> Route {
        guard Self.isValidDestination(destination) else { throw Failure.invalidDestination(destination) }
        if let route = routes[destination] {
            let alive = if route.isUsersOwn {
                await controlAnswers(destination, at: route.controlPath)
            } else {
                owned[destination]?.isRunning == true
            }
            if alive { return route }
            forget(destination)
        }
        if let task = connecting[destination] { return try await task.value }
        let task = Task { try await self.open(destination) }
        connecting[destination] = task
        defer { connecting[destination] = nil }
        let route = try await task.value
        routes[destination] = route
        return route
    }

    /// Run `command` on the host over its connection. It never logs in by
    /// itself (see the type's comment). `input` is the command's stdin; nil
    /// is `/dev/null`.
    func run(
        _ destination: String,
        _ command: String,
        input: FileHandle? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessRunner.Outcome {
        let route = try await connect(destination)
        guard let executable = configuration.ssh.first,
              let outcome = await ProcessRunner.run(
                  executable,
                  sshArguments(commandArguments(route, destination, command)),
                  environment: ProcessInfo.processInfo.environment,
                  input: input,
                  timeout: timeout
              )
        else { throw Failure.cannotStart(configuration.ssh.joined(separator: " ")) }
        return outcome
    }

    /// Start `command` on the host over its connection, with `stdio` as its
    /// stdin and stdout. It is for a command that does not end by itself
    /// (the server's proxy). stderr goes to the returned pipe. The caller
    /// ends the process.
    func start(_ destination: String, _ command: String, stdio: FileHandle) async throws -> (Process, CollectedPipe) {
        let route = try await connect(destination)
        guard let executable = configuration.ssh.first else { throw Failure.cannotStart("no ssh") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = sshArguments(commandArguments(route, destination, command))
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdio
        process.standardOutput = stdio
        let stderr = CollectedPipe()
        process.standardError = stderr.pipe
        do {
            try process.run()
        } catch {
            stderr.stop()
            throw Failure.cannotStart(EnglishErrorText.describe(error))
        }
        return (process, stderr)
    }

    private func commandArguments(_ route: Route, _ destination: String, _ command: String) -> [String] {
        [
            "-S", route.controlPath,
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "ProxyCommand=/usr/bin/false",
            // A `RemoteCommand` of the user's config refuses a command line.
            "-o", "RemoteCommand=none",
            "-T", "--", destination, command,
        ]
    }

    /// The destination as ssh resolves it from the user's config (`ssh -G`):
    /// `user@hostname:port`. Two names for one machine give one value, and
    /// one name that the config points at another machine gives another.
    /// nil when `ssh -G` fails.
    func resolvedDestination(_ destination: String) async -> String? {
        guard Self.isValidDestination(destination) else { return nil }
        let outcome = await runSSH(["-G", "--", destination], timeout: .seconds(5))
        guard let outcome, outcome.status == 0 else { return nil }
        return SSHControlPath.resolvedDestination(fromConfig: outcome.stdout)
    }

    /// End Macterm's master for `destination`. A user's master stays.
    func disconnect(_ destination: String) {
        owned[destination]?.terminate()
        forget(destination)
    }

    /// The user cancelled a question of the login of the connection `pid`. End the
    /// login: ssh would ask again (the next password try, the next method).
    /// Only the master gets the signal. The ssh of a `ProxyJump` host under
    /// it can ask once more; the app refuses that askpass (no master), and
    /// the ssh then exits on the closed connection.
    func cancelLogin(connectionPID pid: pid_t) {
        guard let process = owned.values.first(where: { $0.processIdentifier == pid }), process.isRunning else { return }
        cancelled.insert(pid)
        process.terminate()
    }

    /// Run `body`, a question of the login of the connection `pid`. While
    /// it runs, the login shows no notice.
    func asking<T>(connectionPID pid: pid_t, _ body: () async -> T) async -> T {
        asking[pid, default: 0] += 1
        defer {
            asking[pid, default: 1] -= 1
            if asking[pid] == 0 { asking[pid] = nil }
        }
        return await body()
    }

    /// At quit: end every master of Macterm.
    func disconnectAll() {
        for process in owned.values {
            process.terminate()
        }
        owned.removeAll()
        routes.removeAll()
    }

    /// The host and the master pid for an askpass `pid`, or nil when no
    /// master of Macterm started that process.
    ///
    /// - The peer must run `askpassExecutable`. A pid alone can be reused.
    /// - A master of Macterm must be its parent, or an ancestor up to
    ///   `askpassAncestry` steps above it. ssh runs its askpass with a direct
    ///   `exec` (`readpass.c`), so for the login of the host itself the
    ///   parent is the master. A `ProxyJump` host's login comes from an ssh
    ///   that the master started through `sh -c`, two steps lower.
    func askpassOwner(forPeer pid: pid_t) -> (host: String, pid: pid_t)? {
        if let expected = configuration.askpassExecutable, !Self.process(pid, runs: expected) { return nil }
        var ancestor = pid
        for _ in 0 ..< Self.askpassAncestry {
            guard let parent = ProcessInspector.parentPID(of: ancestor), parent > 1 else { return nil }
            for (host, process) in owned where process.isRunning && process.processIdentifier == parent {
                return (host, parent)
            }
            ancestor = parent
        }
        return nil
    }

    static let askpassAncestry = 4

    /// Whether `pid` runs the executable at `path`, with links resolved.
    nonisolated static func process(_ pid: pid_t, runs path: String) -> Bool {
        guard let actual = ProcessInspector.executablePath(pid: pid) else { return false }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Connect

    private func open(_ destination: String) async throws -> Route {
        if let path = await userControlPath(destination), await controlAnswers(destination, at: path) {
            logger.info("ssh: host=\(destination, privacy: .public) uses the user's master")
            return Route(controlPath: path, isUsersOwn: true)
        }
        return try await startConnection(destination)
    }

    private func userControlPath(_ destination: String) async -> String? {
        let outcome = await runSSH(["-G", "--", destination], timeout: .seconds(5))
        guard let outcome, outcome.status == 0 else { return nil }
        return SSHControlPath.userPath(fromConfig: outcome.stdout)
    }

    private func controlAnswers(_ destination: String, at path: String) async -> Bool {
        await runSSH(["-O", "check", "-S", path, "--", destination], timeout: .seconds(5))?.status == 0
    }

    private func runSSH(_ arguments: [String], timeout: Duration) async -> ProcessRunner.Outcome? {
        guard let executable = configuration.ssh.first else { return nil }
        return await ProcessRunner.run(
            executable,
            sshArguments(arguments),
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout
        )
    }

    private func sshArguments(_ arguments: [String]) -> [String] {
        Array(configuration.ssh.dropFirst()) + configuration.options + arguments
    }

    private func startConnection(_ destination: String) async throws -> Route {
        let path = SSHControlPath.own(for: destination, in: configuration.controlDirectory)
        guard SSHControlPath.fitsSocket(path) else { throw Failure.controlPathTooLong(path) }
        try FileManager.default.createDirectory(
            at: configuration.controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // A master of an earlier run that the app did not end (a crash, a
        // force quit) still listens there. End it, so that it does not stay
        // with no socket. Then remove what is left: ssh refuses to listen on
        // a path that exists.
        if await controlAnswers(destination, at: path) {
            _ = await runSSH(["-O", "exit", "-S", path, "--", destination], timeout: .seconds(5))
        }
        unlink(path)

        guard let executable = configuration.ssh.first else { throw Failure.cannotStart("no ssh") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = sshArguments([
            // `-S`, not `-o ControlPath=`: ssh splits an `-o` value at
            // spaces, and "Macterm Debug" has one.
            "-M", "-N",
            "-S", path,
            "-o", "ControlPersist=no",
            "-o", "ConnectTimeout=10",
            "--", destination,
        ])
        var environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        if let askpass = configuration.askpass {
            environment["SSH_ASKPASS"] = askpass
            environment["SSH_ASKPASS_REQUIRE"] = "force"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = CollectedPipe()
        process.standardError = stderr.pipe
        process.terminationHandler = { [weak self] process in
            let pid = process.processIdentifier
            Task { @MainActor in self?.connectionExited(destination, process: process, pid: pid) }
        }
        do {
            try process.run()
        } catch {
            stderr.stop()
            throw Failure.cannotStart(EnglishErrorText.describe(error))
        }
        owned[destination] = process
        // A pid that an earlier, cancelled master had.
        cancelled.remove(process.processIdentifier)

        // ssh listens on the control socket only after the login.
        let pid = process.processIdentifier
        var notice = SSHLoginNotice()
        var shown: String?
        defer {
            asking[pid] = nil
            if shown != nil { onLoginNotice?(destination, pid, nil) }
        }
        while !FileManager.default.fileExists(atPath: path) {
            let line = notice.update(text: stderr.text, asking: asking[pid] != nil, now: .now)
            if line != shown {
                shown = line
                onLoginNotice?(destination, pid, line)
            }
            guard process.isRunning else {
                if process.isRunning { process.terminate() }
                await stderr.finish(within: ProcessRunner.drainTimeout)
                if owned[destination] === process { owned[destination] = nil }
                if cancelled.remove(process.processIdentifier) != nil {
                    logger.info("ssh: host=\(destination, privacy: .public) login cancelled")
                    throw Failure.cancelled
                }
                let reason = SSHControlPath.lastLine(of: stderr.text)
                logger.info("ssh: host=\(destination, privacy: .public) login failed: \(reason, privacy: .public)")
                throw Failure.loginFailed(reason)
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        stderr.discard()
        let count = logins[destination, default: 0] + 1
        logins[destination] = count
        logger.info("ssh login: host=\(destination, privacy: .public) logins=\(count, privacy: .public)")
        return Route(controlPath: path, isUsersOwn: false)
    }

    private func connectionExited(_ destination: String, process: Process, pid: pid_t) {
        onConnectionExit?(pid)
        guard owned[destination] === process else { return }
        logger.info("ssh: host=\(destination, privacy: .public) master exited")
        forget(destination)
    }

    private func forget(_ destination: String) {
        routes[destination] = nil
        owned[destination] = nil
    }

    /// `[user@]host` and nothing that ssh could read as an option or that a
    /// shell could split. Fail closed: a project path from a file must
    /// never become an ssh option.
    nonisolated static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return false }
        return destination.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

/// When a login that asks nothing shows ssh's text. Pure.
///
/// One rule for every host, with no match on a vendor's text: the last line
/// that ssh wrote since the last question, once it has stayed the same for
/// `delay`. ssh's own warnings ("Warning: Permanently added …", "** WARNING:
/// connection is not using a post-quantum key exchange …" and the lines
/// under it) are notices for a terminal, not a reason to wait, so they do
/// not count.
struct SSHLoginNotice {
    static let delay: Duration = .seconds(2)

    /// The bytes of ssh's text up to the last question.
    private var mark = 0
    private var line: String?
    private var since: ContinuousClock.Instant?

    /// The line to show now, or nil.
    mutating func update(text: String, asking: Bool, now: ContinuousClock.Instant) -> String? {
        let bytes = Array(text.utf8)
        if asking {
            mark = bytes.count
            line = nil
            since = nil
            return nil
        }
        let new = String(decoding: bytes.dropFirst(mark), as: UTF8.self)
        let candidate = SSHLoginPrompts.displayText(new)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Warning: ") && !$0.hasPrefix("** ") }
        if candidate != line {
            line = candidate
            since = now
        }
        guard let line, let since, now - since >= Self.delay else { return nil }
        return line
    }
}

/// ControlPath rules. Pure.
enum SSHControlPath {
    /// Macterm's own path for `destination`: a hash, so that any destination
    /// gives a short name with no special characters.
    static func own(for destination: String, in directory: URL) -> String {
        let digest = SHA256.hash(data: Data(destination.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).path
    }

    /// ssh binds a temporary name first, the path plus a dot and 16
    /// characters, and `sun_path` holds 104 bytes with its NUL.
    static func fitsSocket(_ path: String) -> Bool {
        path.utf8.count + 17 < 104
    }

    /// The ControlPath that the user's ssh config gives a host, from the
    /// output of `ssh -G` (ssh expands `%C`, `~` and the other tokens there).
    /// nil when the config names none.
    static func userPath(fromConfig output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "controlpath" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value.lowercased() == "none" ? nil : value
        }
        return nil
    }

    /// `user@hostname:port` from the output of `ssh -G`. nil when a value
    /// is missing.
    static func resolvedDestination(fromConfig output: String) -> String? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if ["user", "hostname", "port"].contains(key), values[key] == nil {
                values[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let user = values["user"], let hostname = values["hostname"], let port = values["port"],
              !user.isEmpty, !hostname.isEmpty, !port.isEmpty
        else { return nil }
        return "\(user)@\(hostname):\(port)"
    }

    static func lastLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
