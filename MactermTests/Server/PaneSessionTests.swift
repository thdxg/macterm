import Foundation
@testable import Macterm
import Testing

/// A pane session against the bundled server, in a runtime directory of its
/// own (see `LocalServerTests`), with a host that records what it is given.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneSessionTests {
    @Test
    func a_session_is_made_fed_and_ends_with_the_exit_status() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let session = PaneSession(
                name: "ps-\(UInt32.random(in: 0 ... .max))",
                launch: .init(
                    cwd: NSTemporaryDirectory(),
                    argv: ["/bin/sh", "-c", "printf up-%s ok; read l; printf got-%s \"$l\"; exit 5"],
                    env: []
                ),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("up-ok") }
            session.sendInput(Data("hi\n".utf8))
            try await host.waitFor { $0.exit != nil }
            let state = host.snapshot()
            #expect(state.screen.contains("got-hi"))
            #expect(state.exit?.code == 5)
            session.stop()
        }
    }

    @Test
    func the_size_goes_to_the_session_when_the_client_claims() async throws {
        try await withServer { server in
            let host = RecordingPaneHost(grid: PaneGrid(cols: 91, rows: 17))
            let session = PaneSession(
                name: "ps-size-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "sleep 1; stty size; sleep 30"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            session.claim(grid: nil)
            try await host.waitFor { $0.screen.contains("17 91") }
            session.stop()
        }
    }

    @Test
    func a_lost_connection_is_made_again_and_the_screen_is_drawn_again() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let connections = ConnectionBox()
            let session = PaneSession(
                name: "ps-lost-\(UInt32.random(in: 0 ... .max))",
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf before-%s lost; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await connections.next(server) }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("before-lost") }
            connections.current?.close()
            try await host.waitFor { $0.linkLost > 0 }
            try await host.waitFor { $0.resets >= 2 && $0.screen.contains("before-lost") }
            session.stop()
        }
    }

    @Test
    func a_session_that_was_killed_ends_the_pane_and_is_not_made_again() async throws {
        try await withServer { server in
            let host = RecordingPaneHost()
            let name = "ps-kill-\(UInt32.random(in: 0 ... .max))"
            let session = PaneSession(
                name: name,
                launch: .init(cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", "printf alive-%s ok; sleep 60"], env: []),
                wantsForeground: false,
                host: host,
                connect: { try await server.connect() }
            )
            session.start()
            try await host.waitFor { $0.screen.contains("alive-ok") }
            let other = try await server.connect()
            defer { other.close() }
            _ = try await other.call(MactermProtocol.SessionKill.self, .init(id: name))
            try await host.waitFor { $0.exit != nil }
            let sessions = try await other.call(MactermProtocol.SessionList.self, .init()).sessions
            #expect(sessions.isEmpty)
            session.stop()
        }
    }

    // MARK: - Support

    /// Holds the connection that a session got, so that a test can end it.
    final class ConnectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ServerConnection?
        var current: ServerConnection? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func next(_ server: LocalServer) async throws -> ServerConnection {
            let connection = try await server.connect()
            store(connection)
            return connection
        }

        private func store(_ connection: ServerConnection) {
            lock.lock()
            stored = connection
            lock.unlock()
        }
    }

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

    private static func cleanUp(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }
}

struct RemotePaneDriverTests {
    @Test
    func a_line_of_macterm_starts_on_a_line_of_its_own_and_ends_with_cr_lf() {
        #expect(RemotePaneDriver.paneText("box refuses.\nPress a key.") == "\r\nbox refuses.\r\nPress a key.\r\n")
    }
}
