import Foundation
@testable import Macterm
import Testing

/// Runs the bundled server in a runtime directory of its own, so that no test
/// meets the server or the sessions of the Macterm that runs on this Mac.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalServerTests {
    // MARK: - Against the real server

    @Test
    func a_connect_starts_the_server_when_none_answers() async throws {
        try await withServer { server in
            #expect(!FileManager.default.fileExists(atPath: server.socketPath))
            let connection = try await server.connect()
            defer { connection.close() }
            #expect(connection.serverHello.role == .server)
            #expect(connection.serverHello.level == MactermProtocol.level)
            #expect(FileManager.default.fileExists(atPath: server.socketPath))
            try await stopServer(connection)
        }
    }

    @Test
    func a_second_connect_uses_the_running_server() async throws {
        try await withServer { server in
            let first = try await server.connect()
            defer { first.close() }
            let second = try await server.connect()
            defer { second.close() }
            #expect(first.serverHello.epoch == second.serverHello.epoch)
            #expect(first.serverPID == second.serverPID)
            try await stopServer(second)
        }
    }

    @Test
    func a_newer_app_replaces_an_older_server_and_its_sessions_keep_running() async throws {
        try await withServer { server in
            let old = try await server.connect()
            defer { old.close() }
            let id = "replace-\(UInt32.random(in: 0 ... .max))"
            _ = try await old.call(MactermProtocol.SessionCreate.self, Self.args(id: id, command: ["/bin/sleep", "60"]))

            // The same binary, but this app names another build of it.
            var newer = server
            newer.buildTag = "newer-than-the-bundle"
            let connection = try await newer.connect()
            defer { connection.close() }
            #expect(connection.serverHello.epoch != old.serverHello.epoch)
            #expect(connection.serverPID != old.serverPID)

            let sessions = try await connection.call(MactermProtocol.SessionList.self, .init()).sessions
            #expect(sessions.map(\.id) == [id])
            #expect(sessions.first?.state == .running)
            _ = try await connection.call(MactermProtocol.SessionKill.self, .init(id: id))
            try await stopServer(connection)
        }
    }

    @Test
    func a_session_is_created_reports_its_exit_and_is_killed() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "exit-\(UInt32.random(in: 0 ... .max))"
            var events = connection.events.makeAsyncIterator()

            let created = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "exit 3"])
            ).session
            #expect(created.id == id)

            let exit = try await Self.firstExit(&events)
            #expect(exit == MactermProtocol.SessionExit(id: id, code: 3, signal: nil))
            let info = try await connection.call(MactermProtocol.SessionInfo.self, .init(id: id)).session
            #expect(info.state == .exited)
            #expect(info.code == 3)

            _ = try await connection.call(MactermProtocol.SessionKill.self, .init(id: id))
            let sessions = try await connection.call(MactermProtocol.SessionList.self, .init()).sessions
            #expect(sessions.isEmpty)
            await #expect(throws: ProtocolControlError.self) {
                try await connection.call(MactermProtocol.SessionInfo.self, .init(id: id))
            }
            try await stopServer(connection)
        }
    }

    @Test
    func a_running_session_is_killed() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "kill-\(UInt32.random(in: 0 ... .max))"
            let created = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sleep", "60"])
            ).session
            #expect(created.state == .running)
            let pid = try #require(created.shellPid)

            _ = try await connection.call(MactermProtocol.SessionKill.self, .init(id: id))
            #expect(try await connection.call(MactermProtocol.SessionList.self, .init()).sessions.isEmpty)
            // The shell can be a zombie for a moment after the reply.
            let deadline = Date().addingTimeInterval(5)
            while Darwin.kill(pid_t(pid), 0) == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(Darwin.kill(pid_t(pid), 0) != 0)
            try await stopServer(connection)
        }
    }

    @Test
    func a_closed_connection_fails_its_requests_and_ends_its_events() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            try await stopServer(connection)
            connection.close()
            for await _ in connection.events {}
            await #expect(throws: ServerClientError.disconnected) {
                try await connection.call(MactermProtocol.SessionList.self, .init())
            }
        }
    }

    // MARK: - The rule for an older server

    private let server = LocalServer(
        executable: URL(fileURLWithPath: "/Applications/Macterm.app/Contents/Resources/zmx/zmx"),
        directory: URL(fileURLWithPath: "/tmp/run"),
        buildTag: "abc"
    )

    private func hello(level: UInt32 = MactermProtocol.level, build: String) -> MactermProtocol.Hello {
        .init(level: level, minLevel: 1, build: build, role: .server, epoch: 1, caps: [])
    }

    @Test
    func a_lower_level_is_older_and_a_higher_level_is_never_replaced() {
        let path = LocalServer.ServerExecutable.path(server.executable.path)
        #expect(server.shouldReplace(hello(level: MactermProtocol.level - 1, build: "1.0.1+thdxg.abc"), executable: .unknown))
        #expect(!server.shouldReplace(hello(level: MactermProtocol.level + 1, build: "1.0.1+thdxg.old"), executable: path))
    }

    @Test
    func another_build_of_the_same_level_is_replaced_only_from_this_apps_path_or_a_removed_file() {
        let other = hello(build: "1.0.1+thdxg.old")
        #expect(server.shouldReplace(other, executable: .path(server.executable.path)))
        #expect(server.shouldReplace(other, executable: .gone))
        #expect(!server.shouldReplace(other, executable: .path("/Applications/Macterm Debug.app/Contents/Resources/zmx/zmx")))
        #expect(!server.shouldReplace(other, executable: .unknown))
        #expect(!server.shouldReplace(hello(build: "1.0.1+thdxg.abc"), executable: .gone))

        var unknownBuild = server
        unknownBuild.buildTag = nil
        #expect(!unknownBuild.shouldReplace(other, executable: .gone))
    }

    @Test
    func the_runtime_directory_is_found_as_the_server_finds_it() {
        #expect(LocalServer.runtimeDirectory(environment: [
            "MACTERM_RUNTIME_DIR": "/a", "XDG_RUNTIME_DIR": "/b", "TMPDIR": "/c/",
        ])?.path == "/a")
        #expect(LocalServer.runtimeDirectory(environment: ["XDG_RUNTIME_DIR": "/b", "TMPDIR": "/c/"])?.path == "/b/macterm")
        #expect(LocalServer.runtimeDirectory(environment: ["MACTERM_RUNTIME_DIR": "", "TMPDIR": "/c/"])?.path == "/c/macterm")
        #expect(LocalServer.runtimeDirectory(environment: ["HOME": "/h"])?.path == "/h/.local/state/macterm/run")
        #expect(LocalServer.runtimeDirectory(environment: [:]) == nil)
    }

    // MARK: - Helpers

    /// A server of the bundled build in a new runtime directory. The
    /// directory is short: a socket path has at most 103 bytes.
    private func withServer(_ body: (LocalServer) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        do {
            try await body(server)
        } catch {
            await Self.cleanUp(server)
            throw error
        }
        await Self.cleanUp(server)
    }

    /// Leaves no session and no server behind, also after a failed check.
    private static func cleanUp(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }

    private func stopServer(_ connection: ServerConnection) async throws {
        _ = try await connection.call(MactermProtocol.ServerExit.self, .init())
    }

    private static func args(id: String, command: [String]) -> MactermProtocol.SessionCreate.Args {
        .init(
            id: id,
            cwd: ProtocolBin(Data(NSTemporaryDirectory().utf8)),
            command: command.map { ProtocolBin(Data($0.utf8)) },
            cols: 80,
            rows: 24
        )
    }

    private static func firstExit(
        _ events: inout AsyncStream<[ServerEvent]>.Iterator
    ) async throws -> MactermProtocol.SessionExit {
        while let batch = await events.next() {
            for case let .sessionExit(exit) in batch {
                return exit
            }
        }
        throw ServerClientError.disconnected
    }
}
