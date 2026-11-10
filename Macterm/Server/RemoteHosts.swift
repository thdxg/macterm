import Foundation
import notify
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteHosts")

/// What a remote pane's client asks (`macterm remote-pane`, 0057).
enum RemotePaneEvent: String, Codable {
    /// What now: at the start, and after the app woke the client.
    case ask
    /// The pane's ssh exited 255: the connection stopped.
    case lost
    /// The user pressed a key in a pane that waits: connect now.
    case retry
    /// The user pressed Return at "the session ended": a new shell.
    case create
}

/// The app's answer to a remote pane's client.
enum RemotePaneAnswer: Equatable {
    /// Wait for the wake notification or a key. `message` goes into the pane
    /// first.
    case wait(message: String?)
    /// Run this ssh on the pane's tty. `clear`: clear the screen and the
    /// scrollback first, because the session sends its own on attach.
    case run(arguments: [String], clear: Bool, message: String?)
    /// The pane's session is gone (the host restarted). Ask for Return.
    case ended(message: String)
    /// No pane has the session any more: the client ends.
    case close
}

/// Each remote pane is a session of the host's server, reached over the
/// host's one ssh connection (0057). This type keeps, for each host, the
/// route of that connection and one link to the server (`RemoteServers.Link`),
/// and answers each pane's client (`macterm remote-pane`).
///
/// - **The interim shape.** The client runs on the pane's pty, as
///   `macterm attach` does for a local pane, until the GUI feeds a surface
///   from a channel (m3). It runs `ssh -S <master> -t <host> 'macterm-<key>
///   connect <name>'`: each pane is one ssh channel over the one connection,
///   so one login serves every pane. The link to the server lists and ends
///   sessions.
/// - **One request is short.** A login or an install can wait minutes for the
///   user, and the control socket has 16 connections. So `answer` never waits
///   for them: it starts the work and says `wait`; when the work ends, the
///   app posts the pane's Darwin notification (`wakeName`), and the client
///   asks again.
/// - **Lost.** A client whose ssh exits 255 reports `lost`. The pane dims
///   (`Pane.isRemoteLinkLost`) and waits for a trigger (wake, a network
///   change, activation, the project's selection; `AppState.
///   reconnectDroppedRemotePanes` with `RemoteReconnectPolicy`) or a key in
///   the pane. The attach after it replays the session's screen.
/// - **Ended.** A pane whose session ran on the host
///   (`Pane.hostSessionDirectory`) and is gone there (a host restart) asks
///   for Return, then starts a new shell in the same folder. A server is
///   never started empty in silence for a pane that expects a session. A
///   pane from before v2 has no such folder: its first session starts with
///   no question, as local panes did at the cut-over.
/// - **No server.** When the user declined the install, or the host has no
///   build, each pane is a plain ssh shell, with one line that says so. The
///   decline is kept (`declined`); Settings → Projects offers the install
///   again.
/// - v1 sessions on a host keep running: nothing here ends one.
@MainActor @Observable
final class RemoteHosts {
    struct Configuration {
        /// The build key of the bundled server.
        var key: String?
        /// Posts a Darwin notification.
        var post: (String) -> Void = { notify_post($0) }
        var declines: DeclineStore
        /// How long a session that the app told a client to make counts as
        /// made (`created`).
        var creationGrace: TimeInterval = 30

        static var live: Configuration {
            Configuration(key: ServerBuilds.bundledKey, declines: .preferences)
        }
    }

    /// The destinations whose server install the user declined.
    struct DeclineStore {
        var read: @MainActor () -> [String]
        var write: @MainActor ([String]) -> Void

        static var preferences: DeclineStore {
            DeclineStore(
                read: { Preferences.shared.remoteServerDeclines },
                write: { Preferences.shared.remoteServerDeclines = $0 }
            )
        }
    }

    static let shared = RemoteHosts(connections: .shared, servers: .shared, configuration: .live)

    /// The destinations whose panes are plain ssh shells, because the user
    /// declined the install of the server there.
    private(set) var declined: Set<String>

    private let connections: SSHConnections
    private let servers: RemoteServers
    private let configuration: Configuration

    private enum Host {
        /// A login and a check run. The token tells this prepare from a
        /// later one.
        case preparing(UUID, Task<Void, Never>)
        case ready(SSHConnections.Route, RemoteServers.Link)
        /// No server: plain shells.
        case plain(SSHConnections.Route)
    }

    @ObservationIgnored private var hosts: [String: Host] = [:]
    /// The sessions that wait for their host to be ready.
    @ObservationIgnored private var waiting: [String: Set<String>] = [:]
    /// Sessions whose connection stopped: they wait for a trigger or a key.
    @ObservationIgnored private var lost: Set<String> = []
    /// Sessions that ended on the host and wait for Return.
    @ObservationIgnored private var ended: Set<String> = []
    /// Sessions whose user pressed Return at "the session ended".
    @ObservationIgnored private var createRequested: Set<String> = []
    /// A line for a session's pane, given with the next answer.
    @ObservationIgnored private var messages: [String: String] = [:]
    /// Lists that failed on the current link of a host, in a row.
    @ObservationIgnored private var listFailures: [String: Int] = [:]
    /// When the app last told a session's client to make it. A second client
    /// (a mirror) can ask before the host lists the new session, and a
    /// channel can drop before the session starts: in this time a missing
    /// session is made, not reported as ended.
    @ObservationIgnored private var created: [String: Date] = [:]

    init(connections: SSHConnections, servers: RemoteServers, configuration: Configuration) {
        self.connections = connections
        self.servers = servers
        self.configuration = configuration
        declined = Set(configuration.declines.read())
    }

    /// The Darwin notification that wakes the client of `session`.
    nonisolated static func wakeName(for session: String) -> String {
        "\(appBundleID).remote-pane.\(session)"
    }

    // MARK: - A pane's client

    /// The answer to `event` from the client of `session`. `panes` are the
    /// panes that show the session (a mirror shows it too); none means the
    /// pane closed.
    func answer(_ event: RemotePaneEvent, session: String, panes: [Pane]) async -> RemotePaneAnswer {
        guard let pane = panes.first, let target = Target(pane) else { return .close }
        switch event {
        case .ask:
            if lost.contains(session) {
                mark(panes, lost: true)
                return .wait(message: messages.removeValue(forKey: session))
            }
            if ended.contains(session) { return .ended(message: RemotePaneText.ended(host: target.host)) }
        case .lost:
            logger.info("remote pane: session=\(session, privacy: .public) host=\(target.destination, privacy: .public) lost")
            lost.insert(session)
            mark(panes, lost: true)
            // The next connect checks the connection again.
            drop(target.destination)
            return .wait(message: nil)
        case .retry:
            lost.remove(session)
        case .create:
            ended.remove(session)
            createRequested.insert(session)
        }
        return await resolve(session, panes: panes, target: target)
    }

    /// A trigger lets these lost panes connect again. The caller applies
    /// the backoff.
    func reconnect(_ sessions: Set<String>) {
        for session in sessions where lost.remove(session) != nil {
            configuration.post(Self.wakeName(for: session))
        }
    }

    /// End a session on its host, when its pane closed for good. It uses
    /// only a connection that is up: a close never asks for a login. With no
    /// connection, the session stays.
    func endSession(_ session: String, destination: String) async {
        forget(session)
        switch hosts[destination] {
        case let .ready(_, link):
            await Self.kill(session, over: link)
            return
        case .plain:
            return
        case .preparing,
             nil:
            break
        }
        do {
            let link = try await servers.connect(destination, login: false, install: false)
            await Self.kill(session, over: link)
            link.close()
        } catch {
            logger.info("remote session \(session, privacy: .public) stays: \(String(describing: error), privacy: .public)")
        }
    }

    /// Install the server on a host where the user declined it, after the
    /// user's click. New panes then get sessions; a plain shell stays plain.
    func installServer(_ destination: String) async throws {
        undecline(destination)
        if case let .preparing(_, task) = hosts[destination] { await task.value }
        drop(destination)
        let route = try await connections.connect(destination)
        do {
            let link = try await servers.connect(destination)
            if case let .ready(_, old) = hosts[destination] { old.close() }
            hosts[destination] = .ready(route, link)
        } catch RemoteServers.Failure.declined {
            decline(destination)
            throw RemoteServers.Failure.declined
        }
    }

    // MARK: - Steps

    /// What a pane needs from its project path.
    private struct Target {
        var destination: String
        var host: String
        var directory: String

        init?(_ pane: Pane) {
            guard case let .remote(user, host, directory) = pane.remoteSpec else { return nil }
            let destination = RemoteSpawn.destination(user: user, host: host)
            guard SSHConnections.isValidDestination(destination) else { return nil }
            self.destination = destination
            self.host = host
            self.directory = directory
        }
    }

    private func resolve(_ session: String, panes: [Pane], target: Target) async -> RemotePaneAnswer {
        let destination = target.destination
        switch hosts[destination] {
        case nil:
            prepare(destination, host: target.host)
            waiting[destination, default: []].insert(session)
            return .wait(message: nil)
        case .preparing:
            waiting[destination, default: []].insert(session)
            return .wait(message: nil)
        case let .plain(route):
            mark(panes, lost: false)
            return .run(
                arguments: connections.ttyArguments(
                    route, destination, RemoteSpawn.plainShellCommand(directory: target.directory)
                ),
                clear: false,
                message: RemotePaneText.plainShell(host: target.host)
            )
        case let .ready(route, link):
            return await decide(session, panes: panes, target: target, route: route, link: link)
        }
    }

    private func decide(
        _ session: String,
        panes: [Pane],
        target: Target,
        route: SSHConnections.Route,
        link: RemoteServers.Link
    ) async -> RemotePaneAnswer {
        let destination = target.destination
        guard let key = configuration.key else { return .close }
        guard let sessions = await Self.list(over: link) else {
            // The link broke. Only a failure on the host's current link
            // counts, and drops it: another request may have made a new one
            // meanwhile. Two failures in a row are the host's answer.
            guard case let .ready(_, current) = hosts[destination], current === link else {
                return await resolve(session, panes: panes, target: target)
            }
            drop(destination)
            let failures = listFailures[destination, default: 0] + 1
            listFailures[destination] = failures
            guard failures < 2 else {
                listFailures[destination] = nil
                lost.insert(session)
                mark(panes, lost: true)
                return .wait(message: RemotePaneText.withRetry(RemotePaneText.serverSilent(host: target.host)))
            }
            return await resolve(session, panes: panes, target: target)
        }
        listFailures[destination] = nil
        let found = sessions.first { $0.name == session }
        if let found, !found.isRunning {
            // The shell exited while no pane showed it.
            await Self.kill(session, over: link)
        }
        // A folder that the host reported must be safe for a command line.
        let known = panes.lazy.compactMap(\.hostSessionDirectory).first
            .map { RemoteSpawn.isSafeHostFolder($0) ? $0 : target.directory }
        let justCreated = created[session].map { Date().timeIntervalSince($0) < configuration.creationGrace } ?? false
        if found?.isRunning == true { created[session] = nil }
        let step = Self.step(
            running: found?.isRunning == true,
            sessionDirectory: known,
            createRequested: createRequested.remove(session) != nil || justCreated,
            projectDirectory: target.directory
        )
        switch step {
        case .attach:
            mark(panes, lost: false)
            for pane in panes where pane.hostSessionDirectory == nil {
                pane.hostSessionDirectory = target.directory
            }
            let command = RemoteSpawn.sessionCommand(key: key, sessionName: session, create: nil)
            return .run(arguments: connections.ttyArguments(route, destination, command), clear: true, message: nil)
        case let .create(directory):
            mark(panes, lost: false)
            created[session] = Date()
            for pane in panes {
                pane.hostSessionDirectory = directory
            }
            // A mirror that waits at "the session ended" attaches now.
            if ended.remove(session) != nil || panes.count > 1 {
                configuration.post(Self.wakeName(for: session))
            }
            let command = RemoteSpawn.sessionCommand(key: key, sessionName: session, create: directory)
            return .run(arguments: connections.ttyArguments(route, destination, command), clear: false, message: nil)
        case .ended:
            logger.info("remote pane: session=\(session, privacy: .public) ended on \(destination, privacy: .public)")
            ended.insert(session)
            mark(panes, lost: false)
            return .ended(message: RemotePaneText.ended(host: target.host))
        }
    }

    enum Step: Equatable {
        case attach
        case create(directory: String)
        case ended
    }

    /// What a pane does with its session. A running session attaches. A
    /// missing one starts in the pane's folder when the user asked, or when
    /// the pane never had a session on the host (a new pane, or one from
    /// before v2). Otherwise it ended: the pane asks. Pure.
    nonisolated static func step(
        running: Bool,
        sessionDirectory: String?,
        createRequested: Bool,
        projectDirectory: String
    ) -> Step {
        if running { return .attach }
        if createRequested { return .create(directory: sessionDirectory ?? projectDirectory) }
        guard sessionDirectory != nil else { return .create(directory: projectDirectory) }
        return .ended
    }

    /// Log in, then check and install the server, for the sessions that
    /// wait. The end wakes them.
    private func prepare(_ destination: String, host: String) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<Host, PrepareFailure>
            do {
                result = try await .success(open(destination))
            } catch {
                logger.info("remote host \(destination, privacy: .public): \(String(describing: error), privacy: .public)")
                result = .failure(PrepareFailure(message: RemotePaneText.connectFailure(error, host: host)))
            }
            finish(destination, token: token, result)
        }
        hosts[destination] = .preparing(token, task)
    }

    private struct PrepareFailure: Error {
        var message: String
    }

    private func open(_ destination: String) async throws -> Host {
        let route = try await connections.connect(destination)
        do {
            let link = try await servers.connect(destination, install: !declined.contains(destination))
            return .ready(route, link)
        } catch let failure as RemoteServers.Failure {
            switch failure {
            case .declined:
                decline(destination)
                return .plain(route)
            case .notInstalled,
                 .noWritableHome,
                 .unsupported,
                 .noBuild,
                 .notBundled:
                logger.info("remote host \(destination, privacy: .public): plain shells: \(failure.description, privacy: .public)")
                return .plain(route)
            default:
                throw failure
            }
        }
    }

    private func finish(_ destination: String, token: UUID, _ result: Result<Host, PrepareFailure>) {
        let sessions = waiting.removeValue(forKey: destination) ?? []
        guard case let .preparing(current, _) = hosts[destination], current == token else {
            // Another step replaced this prepare (an install from Settings).
            // Its waiting panes ask again and find that step's state.
            if case let .success(.ready(_, link)) = result { link.close() }
            for session in sessions {
                configuration.post(Self.wakeName(for: session))
            }
            return
        }
        switch result {
        case let .success(host):
            hosts[destination] = host
        case let .failure(failure):
            hosts[destination] = nil
            for session in sessions {
                lost.insert(session)
                messages[session] = RemotePaneText.withRetry(failure.message)
            }
        }
        for session in sessions {
            configuration.post(Self.wakeName(for: session))
        }
    }

    /// Forget a host's link: the next pane checks the connection again.
    private func drop(_ destination: String) {
        switch hosts[destination] {
        case let .ready(_, link):
            link.close()
            hosts[destination] = nil
        case .plain:
            hosts[destination] = nil
        case .preparing,
             nil:
            break
        }
    }

    private func forget(_ session: String) {
        created[session] = nil
        lost.remove(session)
        ended.remove(session)
        createRequested.remove(session)
        messages[session] = nil
        for destination in waiting.keys {
            waiting[destination]?.remove(session)
        }
    }

    private func mark(_ panes: [Pane], lost: Bool) {
        for pane in panes where pane.isRemoteLinkLost != lost {
            pane.isRemoteLinkLost = lost
        }
    }

    private func decline(_ destination: String) {
        declined.insert(destination)
        configuration.declines.write(declined.sorted())
    }

    private func undecline(_ destination: String) {
        guard declined.remove(destination) != nil else { return }
        configuration.declines.write(declined.sorted())
    }

    // MARK: - The link

    private static func list(over link: RemoteServers.Link) async -> [LocalSession]? {
        let connection = link.connection
        do {
            return try await LocalSessions.bounded {
                try await connection.call(MactermProtocol.SessionList.self, .init()).sessions
            }.map(LocalSession.init)
        } catch {
            logger.warning("remote session list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func kill(_ session: String, over link: RemoteServers.Link) async {
        let connection = link.connection
        do {
            _ = try await LocalSessions.bounded {
                try await connection.call(MactermProtocol.SessionKill.self, .init(id: session))
            }
        } catch let ProtocolControlError.errorResponse(info) where info.code == "not_found" {
            return
        } catch {
            logger.warning("remote session kill \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The lines that a remote pane shows (0057). They stay English, as all
/// text that Macterm writes into a pane. Pure.
enum RemotePaneText {
    /// A failed connect, in Macterm's words for ssh's three common errors,
    /// else ssh's last line, cleaned (Ethan, 2026-11-09).
    static func connectFailure(_ error: Error, host: String) -> String {
        switch error {
        case let failure as SSHConnections.Failure:
            switch failure {
            case let .loginFailed(line): loginFailure(line, host: host)
            case .cancelled: "You cancelled the login to \(host)."
            case let .configUnreadable(line): "ssh cannot read its configuration: \(HostCheck.clean(line))"
            default: "Macterm cannot connect to \(host): \(failure.description)."
            }
        case let failure as RemoteServers.Failure:
            "Macterm cannot start its server on \(host): \(failure.description)."
        default:
            "Macterm cannot connect to \(host)."
        }
    }

    static func loginFailure(_ line: String, host: String) -> String {
        if line.contains("Could not resolve hostname") { return "No host is named \(host)." }
        if line.contains("Operation timed out") || line.contains("Connection timed out") { return "\(host) does not answer." }
        if line.contains("Connection refused") { return "\(host) refuses the connection." }
        let cleaned = HostCheck.clean(line)
        return cleaned.isEmpty ? "The login to \(host) failed." : cleaned
    }

    static func withRetry(_ line: String) -> String {
        "\(line)\nPress a key to try again."
    }

    static func serverSilent(host: String) -> String {
        "The server on \(host) does not answer."
    }

    static func plainShell(host: String) -> String {
        "Macterm has no server on \(host). This shell stops when the connection stops."
    }

    static func ended(host: String) -> String {
        "The session on \(host) ended. Press Return to start a new shell."
    }
}
