import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteServers")

/// The app's way to a host's server (design/005, steps 3 to 5), over the
/// host's one ssh connection (`SSHConnections`).
///
/// 1. One command checks and attaches (`server/host/attach.sh`): it execs
///    `~/.local/share/macterm/bin/macterm-<key> proxy` when the file is
///    there, and the proxy's stdio is the protocol stream. A current host
///    costs this one command.
/// 2. Exit 3: no server of this build. The first install on a host asks the
///    user (`askConsent`, design/006 §5). The answer is kept for the
///    destination as `ssh -G` resolves it, the host id and a checksum of the
///    host's public sshd keys, so a name that now points at another machine,
///    or a host key change, asks again. Later builds install with no
///    question.
/// 3. The install (`server/host/install.sh`) streams the bundled gzip build
///    for the host's `uname` over the connection, checks its SHA-256 on the
///    host and moves it into place. Then step 1 again.
/// 4. A proxy of this build can reach a server that another build started.
///    The app tells that server to exit (`server.exit`), once for each
///    connect, and connects again: the sessions keep running. It does this
///    for a lower level, and at the same level only right after it installed
///    its own build: builds of one level have no order, so the newest
///    install wins. A server of a higher level stays: an app never
///    downgrades a host. So two apps of one level on one host (a Debug and
///    a Release build) share the server of the later install, and do not
///    take turns.
///
/// The host id is a file that the first install writes
/// (`~/.local/share/macterm/host-id`), not the machine's own id: a container
/// or a minimal host has no `/etc/machine-id`. A host with no file asks.
///
/// Nothing in the app calls it yet, except the DEBUG verb `host server`:
/// remote panes stay on v1's path until the remote cut-over.
@MainActor
final class RemoteServers {
    struct Configuration {
        var scripts: HostScripts?
        var builds: ServerBuilds
        /// Asks the user to allow the first install on a host. False: no.
        var askConsent: @MainActor (ConsentRequest) async -> Bool
        var consents: ConsentStore
        /// How long the handshake waits for the server's `hello`: the ssh
        /// round trip and a server start.
        var handshakeTimeout: TimeInterval = 15

        static var live: Configuration {
            Configuration(
                scripts: HostScripts.bundled,
                builds: .bundled,
                askConsent: { await RemoteServerConsent.ask($0) },
                consents: .preferences
            )
        }
    }

    struct ConsentRequest: Equatable {
        var host: String
        /// The size of the server on the host, in bytes.
        var size: Int64
    }

    /// The hosts where the user allowed the install: the resolved
    /// destination → the host id.
    struct ConsentStore {
        var read: @MainActor () -> [String: String]
        var write: @MainActor ([String: String]) -> Void

        static var preferences: ConsentStore {
            ConsentStore(
                read: { Preferences.shared.remoteServerConsents },
                write: { Preferences.shared.remoteServerConsents = $0 }
            )
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The bundle has no host scripts or no server build key.
        case notBundled
        case declined
        case noWritableHome
        case unsupported(system: String, machine: String)
        /// The bundle has no build for the host.
        case noBuild(String)
        /// The command of step 1 ended with no `hello` and no answer of the
        /// script: ssh's 255 (a lost link), or a proxy that cannot start.
        case attachFailed(String)
        case installFailed(String)
        /// The host's server needs a newer app.
        case appTooOld(needsLevel: UInt32)
        /// The host's server speaks a level under this app's lowest.
        case serverTooOld(level: UInt32)

        var description: String {
            switch self {
            case .notBundled: "this build of Macterm has no server for hosts"
            case .declined: "the install of the server was declined"
            case .noWritableHome: "the home folder on the host is not writable"
            case let .unsupported(system, machine): "Macterm has no server for \(system) \(machine)"
            case let .noBuild(target): "this build of Macterm has no server for \(target)"
            case let .attachFailed(reason):
                reason.isEmpty ? "the host's server did not answer" : "the host's server did not answer: \(reason)"
            case let .installFailed(reason):
                reason.isEmpty ? "the install of the server failed" : "the install of the server failed: \(reason)"
            case let .appTooOld(level): "the host's server needs Macterm with protocol level \(level)"
            case let .serverTooOld(level): "the host's server speaks protocol level \(level), which is too old"
            }
        }
    }

    /// One connection to a host's server. Call `close()` when done.
    /// Its parts are thread-safe and never change.
    final class Link: @unchecked Sendable {
        let connection: ServerConnection
        let process: Process
        /// This connect installed the server.
        let installed: Bool
        /// The ssh commands that this connect ran over the master.
        let commands: Int

        init(connection: ServerConnection, process: Process, installed: Bool, commands: Int) {
            self.connection = connection
            self.process = process
            self.installed = installed
            self.commands = commands
        }

        func close() {
            connection.close()
            if process.isRunning { process.terminate() }
        }
    }

    static let shared = RemoteServers(connections: .shared, configuration: .live)

    private let connections: SSHConnections
    private let configuration: Configuration
    private var connecting: [String: Task<Link, Error>] = [:]

    init(connections: SSHConnections, configuration: Configuration) {
        self.connections = connections
        self.configuration = configuration
    }

    /// A connection to the server on `destination`, after the login, the
    /// install and the replace that it needs. Connects to one host go one
    /// at a time, so that two never install at once.
    func connect(_ destination: String) async throws -> Link {
        while let busy = connecting[destination] {
            _ = try? await busy.value
        }
        let task = Task { try await self.open(destination) }
        connecting[destination] = task
        defer { connecting[destination] = nil }
        return try await task.value
    }

    private func open(_ destination: String) async throws -> Link {
        guard let key = configuration.builds.key, let command = configuration.scripts?.attachCommand(key: key)
        else { throw Failure.notBundled }
        var commands = 0
        var installed = false
        var replaced = false
        while true {
            commands += 1
            switch try await attach(destination, command: command) {
            case let .connected(connection, process):
                let link = Link(connection: connection, process: process, installed: installed, commands: commands)
                let hello = connection.serverHello
                if !replaced, Self.shouldReplace(hello, key: key, installed: installed) {
                    let old = hello.build
                    logger.info("server: host=\(destination, privacy: .public) replaces build \(old, privacy: .public)")
                    // The server unlinks its socket before it replies, so the
                    // next proxy starts the new server.
                    _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
                    link.close()
                    replaced = true
                    continue
                }
                let build = hello.build
                let count = commands
                logger
                    .info(
                        "server: host=\(destination, privacy: .public) build=\(build, privacy: .public) commands=\(count, privacy: .public)"
                    )
                return link
            case let .ended(status, text):
                guard let check = HostCheck.parse(status: status, stderr: text) else {
                    throw Failure.attachFailed(HostCheck.clean(SSHControlPath.lastLine(of: text)))
                }
                switch check {
                case .noHome:
                    throw Failure.noWritableHome
                case let .unsupported(system, machine):
                    throw Failure.unsupported(system: system, machine: machine)
                case let .missing(host):
                    guard !installed else { throw Failure.installFailed("the server is not there after the install") }
                    try await install(destination, key: key, host: host)
                    commands += 1
                    installed = true
                }
            }
        }
    }

    /// True when the host's server must make way for this build's: a lower
    /// level, or, right after this connect `installed` this build, another
    /// build of the same level (the type's comment, step 4).
    nonisolated static func shouldReplace(_ hello: MactermProtocol.Hello, key: String, installed: Bool) -> Bool {
        if hello.level != MactermProtocol.level { return hello.level < MactermProtocol.level }
        return installed && ZmxVersion.parse(hello.build)?.forkTag != key
    }

    /// The kept answer for a host: its host id and host keys.
    nonisolated static func consentValue(_ host: HostCheck.Missing) -> String? {
        host.hostID.map { "\($0) \(host.hostKeys)" }
    }

    /// True when the user allowed the install on this host before. A
    /// destination that `ssh -G` did not resolve, or a host with no id,
    /// asks.
    nonisolated static func consented(_ consents: [String: String], destination: String?, host: HostCheck.Missing) -> Bool {
        guard let destination, let value = consentValue(host) else { return false }
        return consents[destination] == value
    }

    // MARK: - Steps

    private enum Attempt {
        case connected(ServerConnection, Process)
        /// The command ended before a `hello`.
        case ended(status: Int32, stderr: String)
    }

    private func attach(_ destination: String, command: String) async throws -> Attempt {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw Failure.attachFailed(String(cString: strerror(errno)))
        }
        let ours = pair[0]
        // Both ends: a process that another thread starts meanwhile must not
        // keep a copy. Process gives ssh its own copy as stdin and stdout.
        _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(ours, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let theirs = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        let process: Process
        let stderr: CollectedPipe
        do {
            (process, stderr) = try await connections.start(destination, command, stdio: theirs)
        } catch {
            Darwin.close(ours)
            try? theirs.close()
            throw error
        }
        // The ssh process has its own copy.
        try? theirs.close()
        let timeout = configuration.handshakeTimeout
        let result = await Task.detached {
            Result {
                // A shell rc file of the user can write to stdout first.
                guard let rest = Self.skipToProxy(fd: ours, timeout: timeout) else {
                    Darwin.close(ours)
                    throw ServerClientError.noAnswer
                }
                return try ServerConnection.handshake(fd: ours, peerPID: nil, timeout: timeout, buffered: rest)
            }
        }.value
        switch result {
        case let .success(connection):
            stderr.discard()
            return .connected(connection, process)
        case .failure(ServerClientError.noAnswer):
            let status = await Self.exitStatus(of: process, within: .seconds(5))
            await stderr.finish(within: ProcessRunner.drainTimeout)
            return .ended(status: status, stderr: stderr.text)
        case let .failure(error):
            if process.isRunning { process.terminate() }
            stderr.stop()
            switch error {
            case let ServerClientError.refused(level): throw Failure.appTooOld(needsLevel: level)
            case let ServerClientError.serverTooOld(level): throw Failure.serverTooOld(level: level)
            default: throw Failure.attachFailed(String(describing: error))
            }
        }
    }

    private func install(_ destination: String, key: String, host: HostCheck.Missing) async throws {
        guard let scripts = configuration.scripts else { throw Failure.notBundled }
        guard let target = ZmxHostTarget.detect(system: host.system, machine: host.machine) else {
            throw Failure.unsupported(system: host.system, machine: host.machine)
        }
        guard let build = await configuration.builds.build(for: target) else { throw Failure.noBuild(target.rawValue) }
        let resolved = await connections.resolvedDestination(destination)
        if !Self.consented(configuration.consents.read(), destination: resolved, host: host) {
            guard await configuration.askConsent(ConsentRequest(host: destination, size: build.size)) else {
                logger.info("server: host=\(destination, privacy: .public) install declined")
                throw Failure.declined
            }
        }
        let newID = host.hostID ?? UUID().uuidString.lowercased()
        guard let command = scripts.installCommand(key: key, sha256: build.sha256, hostID: newID) else {
            throw Failure.notBundled
        }
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: build.file)
        } catch {
            throw Failure.installFailed(EnglishErrorText.describe(error))
        }
        defer { try? file.close() }
        let outcome = try await connections.run(destination, command, input: file, timeout: .seconds(120))
        guard outcome.status == 0, let installedID = HostCheck.installedID(in: outcome.stdout) else {
            let reason = HostCheck.clean(HostCheck.reason(in: outcome.stderr) ?? SSHControlPath.lastLine(of: outcome.stderr))
            logger.error("server: host=\(destination, privacy: .public) install failed: \(reason, privacy: .public)")
            throw Failure.installFailed(reason)
        }
        var kept = host
        kept.hostID = installedID
        if let resolved, let value = Self.consentValue(kept) {
            var consents = configuration.consents.read()
            consents[resolved] = value
            configuration.consents.write(consents)
        }
        logger
            .info(
                "server: host=\(destination, privacy: .public) installed \(key, privacy: .public) for \(target.rawValue, privacy: .public)"
            )
    }

    nonisolated static let proxyLine = Data("macterm-host proxy\n".utf8)

    /// Reads `fd` up to and past `proxyLine`, which `attach.sh` prints
    /// before it execs the proxy, and returns the bytes after it. nil at the
    /// end of the stream (exit 3 or 4) or after `timeout`. At most 1 MiB
    /// may come first.
    nonisolated static func skipToProxy(fd: Int32, timeout: TimeInterval) -> Data? {
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count < 1 << 20 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0 ..< count])
            if let range = buffer.range(of: proxyLine) {
                return Data(buffer[range.upperBound...])
            }
        }
        return nil
    }

    /// The exit status of `process`, or -1 when it does not end in `limit`
    /// (it gets SIGTERM then).
    private static func exitStatus(of process: Process, within limit: Duration) async -> Int32 {
        let deadline = ContinuousClock.now + limit
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                process.terminate()
                return -1
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.terminationReason == .exit ? process.terminationStatus : -1
    }
}

/// The scripts that run on a host (`server/host/`, in the bundle at
/// `Contents/Resources/host`). The app sends each one as
/// `sh -c '<script>' macterm <arguments>`, as every remote command
/// (`RemoteSpawn.remoteShell`), so a script has no single quote and each
/// argument is one word.
struct HostScripts: Equatable {
    var attach: String
    var install: String

    static var bundled: HostScripts? {
        Bundle.main.resourceURL.flatMap { load(from: $0.appendingPathComponent("host", isDirectory: true)) }
    }

    /// Each script as the one line that goes to the host (`oneLine`).
    static func load(from directory: URL) -> HostScripts? {
        guard let attach = try? String(contentsOf: directory.appendingPathComponent("attach.sh"), encoding: .utf8),
              let install = try? String(contentsOf: directory.appendingPathComponent("install.sh"), encoding: .utf8)
        else { return nil }
        return HostScripts(attach: oneLine(attach), install: oneLine(install))
    }

    /// The script with no comment lines and no empty lines, its lines joined
    /// with spaces. sshd gives the command to the user's login shell, and csh
    /// refuses a newline in single quotes. So each line of a host script is
    /// valid when it is joined to the next.
    static func oneLine(_ script: String) -> String {
        script.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    func attachCommand(key: String) -> String? {
        Self.command(attach, [key])
    }

    func installCommand(key: String, sha256: String, hostID: String) -> String? {
        Self.command(install, [key, sha256, hostID])
    }

    /// nil when the script has a single quote, a newline or a `!` that csh
    /// reads as history (one that a blank, `=` or `(` does not follow), or an argument
    /// is not one plain word. Fail closed: nothing goes to the host then.
    static func command(_ script: String, _ arguments: [String]) -> String? {
        guard !script.contains("'"), !script.contains(where: \.isNewline), !hasHistoryMark(script),
              arguments.allSatisfy(isWord)
        else { return nil }
        return "sh -c '\(script)' macterm " + arguments.joined(separator: " ")
    }

    static func hasHistoryMark(_ script: String) -> Bool {
        let characters = Array(script)
        return characters.indices.contains { index in
            characters[index] == "!" && index + 1 < characters.count
                && !(characters[index + 1].isWhitespace || "=(".contains(characters[index + 1]))
        }
    }

    /// Letters, digits and `-`, at most 64: a build key, a checksum, a host id.
    static func isWord(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy {
            ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) || $0 == "-"
        }
    }
}

/// What the check of a host says when it finds no server of this build
/// (`server/host/attach.sh`, exit 3 or 4). Pure.
enum HostCheck: Equatable {
    case missing(Missing)
    case noHome
    case unsupported(system: String, machine: String)

    struct Missing: Equatable {
        var system: String
        var machine: String
        /// nil before the first install.
        var hostID: String?
        /// A checksum of the host's public sshd keys.
        var hostKeys: String
    }

    static let marker = "macterm-host"

    /// nil when the status and the text are not the script's: ssh's own
    /// failure, or a host that printed something else.
    static func parse(status: Int32, stderr: String) -> HostCheck? {
        guard let words = lastLine(in: stderr)?.map(clean) else { return nil }
        switch (status, words.first) {
        case (3, "missing") where words.count == 5 && HostScripts.isWord(words[4]):
            let id = words[3] != "-" && HostScripts.isWord(words[3]) ? words[3] : nil
            return .missing(Missing(system: words[1], machine: words[2], hostID: id, hostKeys: words[4]))
        case (4, "no-home"):
            return .noHome
        case (4, "unsupported") where words.count == 3:
            return .unsupported(system: words[1], machine: words[2])
        default:
            return nil
        }
    }

    /// The host id in the install's `macterm-host installed <id>`.
    static func installedID(in stdout: String) -> String? {
        guard let words = lastLine(in: stdout), words.count == 2, words[0] == "installed", HostScripts.isWord(words[1]) else {
            return nil
        }
        return words[1]
    }

    /// The reason in the install's last `macterm-host` line.
    static func reason(in stderr: String) -> String? {
        lastLine(in: stderr)?.joined(separator: " ")
    }

    /// Host text with no control characters, at most 200 characters, for a
    /// log line and an error (design/006 §3).
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).prefix(200))
    }

    /// The words after the marker on the last line that starts with it.
    private static func lastLine(in text: String) -> [String]? {
        text.split(whereSeparator: \.isNewline).reversed()
            .first { $0.hasPrefix(marker + " ") }
            .map { $0.dropFirst(marker.count + 1).split(separator: " ").map(String.init) }
    }
}

/// One gzip server build in the bundle, as the install sends it.
struct ServerBuild: Equatable {
    var target: ZmxHostTarget
    var file: URL
    /// The SHA-256 of the binary, which the host checks after `gunzip`.
    var sha256: String
    /// The size of the binary on the host, in bytes.
    var size: Int64
}

/// The gzip builds that the app carries for every host target
/// (`Contents/Resources/server/macterm-<key>-<target>.gz`, design/007 §3A).
/// The checksum and the size of each one are read once for each run.
actor ServerBuilds {
    nonisolated let key: String?
    private let directory: URL?
    private var measured: [ZmxHostTarget: ServerBuild] = [:]

    init(key: String?, directory: URL?) {
        self.key = key
        self.directory = directory
    }

    static var bundled: ServerBuilds {
        ServerBuilds(
            key: ZmxRelease.bundled?.tag,
            directory: Bundle.main.resourceURL?.appendingPathComponent("server", isDirectory: true)
        )
    }

    func build(for target: ZmxHostTarget) async -> ServerBuild? {
        if let build = measured[target] { return build }
        guard let key, let directory else { return nil }
        let file = directory.appendingPathComponent("macterm-\(key)-\(target.rawValue).gz")
        guard let (sha256, size) = await Task.detached(operation: { Self.measure(file) }).value else { return nil }
        let build = ServerBuild(target: target, file: file, sha256: sha256, size: size)
        measured[target] = build
        return build
    }

    /// The SHA-256 and the size of the binary in a gzip file.
    private static func measure(_ file: URL) -> (String, Int64)? {
        guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        var hash = SHA256()
        var size: Int64 = 0
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
            size += Int64(chunk.count)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, size > 0 else { return nil }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
