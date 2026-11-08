import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LocalSessions")

/// A local v2 session as the server lists it.
struct LocalSession: Equatable {
    var name: String
    /// The session's shell, the leader of its pty. Its controlling tty's
    /// foreground group is the pane's foreground (`ZmxForegroundResolver`).
    var shellPID: pid_t?
    /// The session's pty (`/dev/ttysNNN`).
    var ttyPath: String?
    /// False after the shell exited: the session keeps the status until a
    /// client sends `session.kill`.
    var isRunning: Bool

    init(name: String, shellPID: pid_t? = nil, ttyPath: String? = nil, isRunning: Bool = true) {
        self.name = name
        self.shellPID = shellPID
        self.ttyPath = ttyPath
        self.isRunning = isRunning
    }

    init(_ session: MactermProtocol.Session) {
        self.init(
            name: session.id,
            shellPID: session.shellPid.flatMap { pid_t(exactly: $0) },
            ttyPath: session.pty.map { String(decoding: $0.bytes, as: UTF8.self) },
            isRunning: session.state == .running
        )
    }
}

/// The app's one connection to the local server, for the sessions of its
/// local panes. A pane's surface runs `zmx connect <name> -- <shell>`, which
/// makes a missing session through the same server; this connection lists
/// and ends them.
///
/// It connects at the first use, and again after the connection ends (the
/// server exits when it has no session and no client). The app owns every
/// local session, so a session whose shell exited is ended here: at its
/// `session.exit` event, and at each connect for one that exited while no
/// app was connected. Its pane already closed, or closes from the client's
/// exit.
actor LocalSessions {
    static let shared = LocalSessions(server: LocalServer.bundled)

    private let server: LocalServer?
    private var connection: ServerConnection?
    private var connecting: Task<ServerConnection, Error>?

    init(server: LocalServer?) {
        self.server = server
    }

    /// Every session, or nil when the server cannot be reached.
    func list() async -> [LocalSession]? {
        do {
            let sessions = try await call(MactermProtocol.SessionList.self, .init()).sessions
            return sessions.map(LocalSession.init)
        } catch {
            logger.warning("session list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ends a session and takes its exit status. A session that is not
    /// there is no error.
    func kill(_ name: String) async {
        do {
            _ = try await call(MactermProtocol.SessionKill.self, .init(id: name))
        } catch let ProtocolControlError.errorResponse(info) where info.code == "not_found" {
            return
        } catch {
            logger.warning("session kill \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Connects now, so that the first pane does not wait for it.
    func prepare() async {
        _ = try? await connected()
    }

    private func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args) async throws -> M.Result {
        let connection = try await connected()
        do {
            return try await connection.call(method, args)
        } catch ServerClientError.disconnected {
            // The server exited while idle: one new connection.
            drop(connection)
            return try await connected().call(method, args)
        }
    }

    private func connected() async throws -> ServerConnection {
        if let connection { return connection }
        if let connecting { return try await connecting.value }
        guard let server else { throw ServerClientError.noAnswer }
        let task = Task { try await server.connect() }
        connecting = task
        defer { connecting = nil }
        let connection = try await task.value
        self.connection = connection
        watch(connection)
        return connection
    }

    private func drop(_ old: ServerConnection) {
        guard connection === old else { return }
        old.close()
        connection = nil
    }

    private func watch(_ connection: ServerConnection) {
        Task { [weak self] in
            if let sessions = try? await connection.call(MactermProtocol.SessionList.self, .init()).sessions {
                for session in sessions where session.state == .exited {
                    await self?.kill(session.id)
                }
            }
        }
        Task { [weak self] in
            for await batch in connection.events {
                for case let .sessionExit(exit) in batch {
                    await self?.kill(exit.id)
                }
            }
            await self?.drop(connection)
        }
    }
}
