import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LocalServer")

/// The app's way to the local `macterm server` (design/001, A): it connects
/// to the server's socket, and starts the bundled server when nothing
/// answers. It replaces a server that an older app started (design/002, "The
/// update, step by step").
///
/// Nothing in the app calls it yet: v1's panes still run their own zmx.
struct LocalServer {
    /// The server binary (`Contents/Resources/zmx/zmx` for now).
    var executable: URL
    /// The runtime directory that holds the server's and the sessions'
    /// sockets. The app gives it to the server, so the two agree.
    var directory: URL
    /// The build key of `executable` (`ZmxRelease.tag`). Nil: never replace
    /// a server of the same level.
    var buildTag: String?

    /// The server's socket in `directory` (`socket_name` in `server.zig`).
    static let socketName = ".server"
    /// The variable that names the runtime directory (`runtime.zig`).
    static let directoryVariable = "MACTERM_RUNTIME_DIR"
    /// How long `macterm server` may take to listen.
    static let startTimeout: DispatchTimeInterval = .seconds(10)

    /// The bundled server, or nil when setup put none in the bundle.
    static var bundled: LocalServer? {
        guard let executable = Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx"),
              let directory = runtimeDirectory(environment: ProcessInfo.processInfo.environment)
        else { return nil }
        return LocalServer(executable: executable, directory: directory, buildTag: ZmxRelease.bundled?.tag)
    }

    /// The runtime directory as `resolveDir` in `server/src/runtime.zig`
    /// finds it on macOS, with one folder for each build flavor: `macterm`
    /// for the Release app, `macterm-debug` for the Debug app. So the Debug
    /// app and the Release app never share a server, and a Release pane's
    /// session never runs from the Debug binary (whose signature is not the
    /// app's). The app gives the directory to the server and to every
    /// `zmx connect` in `MACTERM_RUNTIME_DIR`, so the server's own default
    /// never decides.
    static func runtimeDirectory(
        environment: [String: String],
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> URL? {
        func nonEmpty(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        if let dir = nonEmpty(directoryVariable) { return URL(fileURLWithPath: dir, isDirectory: true) }
        let name = folderName(bundleID: bundleID)
        if let dir = nonEmpty("XDG_RUNTIME_DIR") { return URL(fileURLWithPath: dir, isDirectory: true).appending(path: name) }
        if let dir = nonEmpty("TMPDIR") { return URL(fileURLWithPath: dir, isDirectory: true).appending(path: name) }
        guard let home = nonEmpty("HOME") else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).appending(path: ".local/state/\(name)/run")
    }

    /// `macterm` for the Release bundle id, `macterm-<suffix>` for another
    /// flavor (`com.thdxg.macterm.debug` → `macterm-debug`).
    static func folderName(bundleID: String?) -> String {
        let release = "com.thdxg.macterm"
        guard let bundleID, bundleID.hasPrefix(release + "."), bundleID.count > release.count + 1 else { return "macterm" }
        let suffix = bundleID.dropFirst(release.count + 1).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return suffix.isEmpty ? "macterm" : "macterm-\(suffix)"
    }

    var socketPath: String {
        directory.appending(path: Self.socketName).path
    }

    /// A connection to the server, started or replaced first when that is
    /// needed. A server is replaced at most once for each call, so two apps
    /// never replace each other's server in a loop. Call it one at a time:
    /// two calls can both send `server.exit`.
    func connect() async throws -> ServerConnection {
        var replaced = false
        while true {
            let connection: ServerConnection
            do {
                connection = try await open()
            } catch ServerClientError.noAnswer {
                try await start()
                return try await open()
            }
            let executable: ServerExecutable = connection.serverPID.map {
                ProcessInspector.executablePath(pid: $0).map { .path($0) } ?? .gone
            } ?? .unknown
            guard !replaced, shouldReplace(connection.serverHello, executable: executable) else { return connection }
            let old = connection.serverHello
            logger.info("replacing server build \(old.build, privacy: .public) at level \(old.level, privacy: .public)")
            // The server unlinks its socket before it replies, so a start
            // after the reply finds no server.
            _ = try await connection.call(MactermProtocol.ServerExit.self, .init())
            connection.close()
            replaced = true
            try await start()
        }
    }

    private func open() async throws -> ServerConnection {
        let path = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try ServerConnection.connect(path: path) })
            }
        }
    }

    /// Where the running server's binary is.
    enum ServerExecutable: Equatable {
        case path(String)
        /// The kernel gives no path for the process. A process whose file
        /// was deleted (an update removed the old bundle) has none: measured.
        case gone
        /// The kernel did not name the server's process.
        case unknown
    }

    /// True when the server that answers is older than this app's.
    ///
    /// - A lower level is older.
    /// - A higher level is newer: never downgrade it.
    /// - At the same level, another build is older when it runs from this
    ///   app's own path, or from a file that an update removed.
    /// - A build that runs from another app (a Debug build next to a Release
    ///   build) stays. The order of two builds of one level is not known.
    func shouldReplace(_ hello: MactermProtocol.Hello, executable: ServerExecutable) -> Bool {
        if hello.level != MactermProtocol.level { return hello.level < MactermProtocol.level }
        guard let buildTag, ZmxVersion.parse(hello.build)?.forkTag != buildTag else { return false }
        switch executable {
        case let .path(path):
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == self.executable.resolvingSymlinksInPath().path
        case .gone: return true
        case .unknown: return false
        }
    }

    /// Runs `<executable> server`. It returns when the server listens, or at
    /// once when a server answers.
    func start() async throws {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runServerCommand())
            }
        }
        try result.get()
    }

    private func runServerCommand() -> Result<Void, ServerClientError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["server"]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.directoryVariable] = directory.path
        process.environment = environment
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.startFailed(EnglishErrorText.describe(error)))
        }
        guard exited.wait(timeout: .now() + Self.startTimeout) == .success else {
            process.terminate()
            return .failure(.startFailed("The server did not start in time."))
        }
        guard process.terminationStatus == 0 else {
            return .failure(.startFailed(Self.availableText(errors)))
        }
        return .success(())
    }

    /// The text in the pipe now. The server's forked process can hold the
    /// pipe open for a moment, so never wait for its end.
    private static func availableText(_ pipe: Pipe) -> String {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &data, data.count)
        return String(decoding: data.prefix(max(count, 0)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
