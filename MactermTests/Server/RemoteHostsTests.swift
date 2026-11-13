import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteHostsTests {
    // MARK: - Pure rules

    @Test
    func a_running_session_attaches_and_a_missing_one_asks_only_when_it_ran_on_the_host() {
        func step(running: Bool = false, directory: String? = nil, create: Bool = false) -> RemoteHosts.Step {
            RemoteHosts.step(running: running, sessionDirectory: directory, createRequested: create, projectDirectory: "~/app")
        }
        #expect(step(running: true, directory: "/srv") == .attach)
        // A new pane, or one from before v2: a new session, no question.
        #expect(step() == .create(directory: "~/app"))
        // Its session ran on the host and is gone (a host restart): ask.
        #expect(step(directory: "/srv/app/src") == .ended)
        // The user pressed Return: a new shell in the same folder.
        #expect(step(directory: "/srv/app/src", create: true) == .create(directory: "/srv/app/src"))
    }

    @Test
    func a_failed_login_says_why_in_macterms_words_for_the_common_errors() {
        let resolve = "ssh: Could not resolve hostname devbox: nodename nor servname provided, or not known"
        #expect(RemotePaneText.loginFailure(resolve, host: "devbox") == "No host is named devbox.")
        let timeout = "ssh: connect to host 10.0.0.5 port 22: Operation timed out"
        #expect(RemotePaneText.loginFailure(timeout, host: "devbox") == "devbox does not answer.")
        let refused = "ssh: connect to host 10.0.0.5 port 22: Connection refused"
        #expect(RemotePaneText.loginFailure(refused, host: "devbox") == "devbox refuses the connection.")
        // Any other error: ssh's own last line, with no control characters.
        let other = "bob@devbox: Permission denied (publickey).\u{1B}[31m"
        #expect(RemotePaneText.loginFailure(other, host: "devbox") == "bob@devbox: Permission denied (publickey).[31m")
        #expect(RemotePaneText.connectFailure(SSHConnections.Failure.cancelled, host: "devbox") == "You cancelled the login to devbox.")
    }

    @Test
    func a_pane_that_closed_gets_close() async {
        let hosts = RemoteHosts(connections: .shared, servers: .shared, configuration: .init(key: "k", declines: .memory()))
        #expect(await hosts.answer(.ask, session: "macterm-x-1", panes: []).isClose)
        // A local pane has no host.
        let local = Pane(projectPath: "/tmp", projectID: UUID())
        #expect(await hosts.answer(.ask, session: local.sessionName, panes: [local]).isClose)
    }

    // MARK: - Against a local sshd

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func one_login_serves_every_pane_and_the_host_foreground_reaches_the_pane() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let panes = (0 ..< 3).map { _ in fixture.pane() }
            var running: [Fixture.Running] = []
            defer { running.forEach { $0.stop() } }
            for pane in panes {
                let session = try await fixture.start(pane)
                running.append(session)
                session.type("printf 'ready-%s\\n' \(pane.sessionName)\n")
                try await session.host.waitFor { $0.screen.contains("ready-\(pane.sessionName)") }
                #expect(pane.hostSessionDirectory == fixture.directory)
            }
            #expect(host.sshd.acceptedLogins() == 1)
            #expect(host.connections.logins["box"] == 1)

            // The host pushes the foreground of the session on the channel,
            // so a program names the tab and shows its logo with no probe.
            running[0].type("sleep 30\n")
            try await running[0].host.waitFor { $0.foreground?.idle == false }
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_background_read_runs_on_the_hosts_server_with_no_login_of_its_own() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            // No connection yet: a background read never logs in.
            #expect(await fixture.hosts.run(["/bin/sh", "-c", "true"], destination: "box", timeout: .seconds(5)) == nil)
            #expect(host.sshd.acceptedLogins() == 0)

            _ = try await fixture.attach(fixture.pane())
            #expect(fixture.ready == ["box"])
            let result = try #require(
                await fixture.hosts.run(["/bin/sh", "-c", "printf read-%s ok; exit 3"], destination: "box", timeout: .seconds(5))
            )
            #expect(String(decoding: result.output.bytes, as: UTF8.self) == "read-ok")
            #expect(result.code == 3)
            #expect(host.sshd.acceptedLogins() == 1)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_dropped_link_waits_dimmed_and_heals_on_a_trigger() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            let first = try await fixture.start(pane)
            defer { first.stop() }
            first.type("printf 'before-%s\\n' drop\n")
            try await first.host.waitFor { $0.screen.contains("before-drop") }

            // The link drops: the channel ends, and the driver reports it.
            host.sshd.dropConnections()
            try await first.host.waitFor { $0.linkLost > 0 }
            #expect(await fixture.hosts.answer(.lost, session: pane.sessionName, panes: [pane]).isWait(message: nil))
            #expect(pane.isRemoteLinkLost)
            #expect(pane.isDisconnected)
            // No trigger yet: the pane keeps waiting.
            #expect(await fixture.hosts.answer(.ask, session: pane.sessionName, panes: [pane]).isWait(message: nil))

            // A trigger wakes the pane; it logs in again and attaches to the
            // same session, which replays its screen.
            fixture.woken.removeAll()
            fixture.hosts.reconnect([pane.sessionName])
            #expect(fixture.woken == [RemoteHosts.wakeName(for: pane.sessionName)])
            let second = try await fixture.start(pane)
            defer { second.stop() }
            try await second.host.waitFor { $0.screen.contains("before-drop") }
            #expect(!pane.isRemoteLinkLost)
            #expect(host.sshd.acceptedLogins() == 2)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_key_in_one_lost_pane_brings_back_every_lost_pane_of_the_host() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let left = fixture.pane()
            let right = fixture.pane()
            let first = try await fixture.start(left)
            defer { first.stop() }
            let second = try await fixture.start(right)
            defer { second.stop() }
            second.type("printf 'right-%s\\n' up\n")
            try await second.host.waitFor { $0.screen.contains("right-up") }

            host.sshd.dropConnections()
            try await first.host.waitFor { $0.linkLost > 0 }
            try await second.host.waitFor { $0.linkLost > 0 }
            for pane in [left, right] {
                #expect(await fixture.hosts.answer(.lost, session: pane.sessionName, panes: [pane]).isWait(message: nil))
                // Blurred: no line of Macterm's is on it.
                #expect(pane.isRemoteLinkLost && !pane.showsRemoteLinkMessage)
            }

            // A key in the left pane logs in again. The link that came back
            // is a trigger: the sweep wakes the right pane, which attaches
            // with no key and no second login.
            fixture.woken.removeAll()
            let logins = fixture.connected.count
            let again = try await fixture.start(left, event: .retry)
            defer { again.stop() }
            #expect(fixture.connected.dropFirst(logins) == ["box"])
            #expect(!fixture.woken.contains(RemoteHosts.wakeName(for: right.sessionName)))
            fixture.hosts.reconnect([right.sessionName])
            #expect(fixture.woken.contains(RemoteHosts.wakeName(for: right.sessionName)))
            let rightAgain = try await fixture.start(right)
            defer { rightAgain.stop() }
            try await rightAgain.host.waitFor { $0.screen.contains("right-up") }
            #expect(!right.isRemoteLinkLost)
            #expect(host.sshd.acceptedLogins() == 2)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_session_that_ended_on_the_host_asks_before_a_new_shell() async throws {
        try await withSSHDHost { host in
            // The host restarts at once: no grace for a new session.
            let fixture = Fixture(host, creationGrace: 0)
            let pane = fixture.pane()
            let first = try await fixture.start(pane)
            first.type("printf 'up-%s\\n' 1\n")
            try await first.host.waitFor { $0.screen.contains("up-1") }
            first.stop()

            // The host restarts: its server and sessions are gone.
            try await host.stopServer()
            guard case let .ended(message) = await fixture.ask(pane) else {
                Issue.record("the pane did not ask")
                return
            }
            #expect(message.contains("ended"))
            // Return: a new shell in the same folder.
            let (_, create) = try await fixture.attach(pane, event: .create)
            #expect(create == fixture.directory)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_mirror_that_asks_before_the_new_session_starts_makes_it_too() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            _ = try await fixture.attach(pane)
            #expect(pane.hostSessionDirectory == fixture.directory)
            // The first pane has not made its session yet: the host has no
            // session. A second window's view of the pane asks now.
            let mirror = Pane(mirroring: pane)
            let (_, create) = try await fixture.attach(mirror)
            #expect(create == fixture.directory)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_new_session_gets_the_folder_and_the_settled_terminal_environment_from_the_host() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            let (link, create) = try await fixture.attach(pane)
            let directory = try #require(create)
            let made = try #require(await fixture.hosts.createLaunch(link: link, directory: directory))
            #expect(made.note == nil)
            #expect(made.launch.cwd?.hasPrefix("/") == true)
            #expect(made.launch.env.contains("COLORTERM=truecolor"))
            #expect(made.launch.env.contains("TERM_PROGRAM=ghostty"))
            #expect(made.launch.env.contains { $0.hasPrefix("TERM=") })
            let missing = try #require(await fixture.hosts.createLaunch(link: link, directory: "/no/such/folder/here"))
            #expect(missing.note == "macterm: cannot cd to /no/such/folder/here")
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_declined_server_gives_plain_shells_and_asks_once() async throws {
        try await withSSHDHost(answer: false) { host in
            let fixture = Fixture(host)
            for _ in 0 ..< 2 {
                let pane = fixture.pane()
                let answer = await fixture.settle(pane)
                guard case let .plain(arguments, message) = answer else {
                    Issue.record("no plain shell: \(answer)")
                    return
                }
                #expect(message == RemotePaneText.plainShell(host: "box"))
                #expect(arguments.last?.contains("connect") == false)
            }
            #expect(host.asked == ["box"])
            #expect(fixture.hosts.declined == ["box"])
        }
    }

    // MARK: - The probe of a new session

    @Test
    func the_probe_output_gives_the_folder_the_environment_and_a_note_when_the_folder_is_missing() throws {
        let found = try #require(RemoteHosts.parseCreateProbe(
            "ok\n/srv/app\nTERM=xterm-256color\nHOME=/home/a\nnoise\n",
            directory: "~/app"
        ))
        #expect(found.launch.cwd == "/srv/app")
        #expect(found.launch.env == ["TERM=xterm-256color", "HOME=/home/a"])
        #expect(found.note == nil)
        let home = try #require(RemoteHosts.parseCreateProbe("home\n/home/a\nTERM=x\n", directory: "~/gone"))
        #expect(home.note == "macterm: cannot cd to ~/gone")
        #expect(RemoteHosts.parseCreateProbe("ok\nrelative\nTERM=x\n", directory: "~") == nil)
    }

    // MARK: - Fixture

    /// A `RemoteHosts` over the host's connection and server, and panes of
    /// a project on it.
    @MainActor
    private final class Fixture {
        let hosts: RemoteHosts
        let directory: String
        private let posted = LockedBox<[String]>([])
        private let connections = LockedBox<[String]>([])
        /// The hosts whose link came back (`hostDidConnect`).
        var connected: [String] { connections.value }
        private let readyHosts = LockedBox<[String]>([])

        /// The hosts whose link became ready, in order.
        var ready: [String] {
            readyHosts.value
        }

        /// The wakes that the app posted.
        var woken: [String] {
            get { posted.value }
            set { posted.mutate { $0 = newValue } }
        }

        init(_ host: SSHDHost, creationGrace: TimeInterval = 30) {
            directory = host.home.path
            var configuration = RemoteHosts.Configuration(key: host.key, declines: .memory(), creationGrace: creationGrace)
            configuration.post = { [posted] name in posted.mutate { $0.append(name) } }
            configuration.hostDidConnect = { [connections] destination in connections.mutate { $0.append(destination) } }
            configuration.linkReady = { [readyHosts] destination in readyHosts.mutate { $0.append(destination) } }
            hosts = RemoteHosts(connections: host.connections, servers: host.servers, configuration: configuration)
        }

        func pane() -> Pane {
            Pane(projectPath: "box:\(directory)", projectID: UUID())
        }

        /// The answer after the waits that a login or an install cause.
        func settle(_ pane: Pane, event: RemotePaneEvent = .ask) async -> RemotePaneAnswer {
            var answer = await hosts.answer(event, session: pane.sessionName, panes: [pane])
            let deadline = Date().addingTimeInterval(60)
            while answer.isWait(message: nil), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                answer = await hosts.answer(.ask, session: pane.sessionName, panes: [pane])
            }
            return answer
        }

        func ask(_ pane: Pane) async -> RemotePaneAnswer {
            await settle(pane)
        }

        /// The link that the pane attaches over, and the folder when it
        /// makes its session.
        func attach(_ pane: Pane, event: RemotePaneEvent = .ask) async throws -> (link: RemoteServers.Link, create: String?) {
            let answer = await settle(pane, event: event)
            guard case let .attach(link, create) = answer else {
                throw Unexpected(answer: answer)
            }
            return (link, create)
        }

        struct Running {
            let session: PaneSession
            let host: RecordingPaneHost

            func type(_ text: String) {
                session.sendInput(Data(text.utf8))
            }

            func stop() {
                session.stop()
            }
        }

        /// What the pane's driver does: the session on the host's link, with
        /// no reconnect of its own.
        func start(_ pane: Pane, event: RemotePaneEvent = .ask) async throws -> Running {
            let (link, create) = try await attach(pane, event: event)
            var launch: PaneSession.Launch?
            if let create {
                launch = try #require(await hosts.createLaunch(link: link, directory: create)).launch
            }
            let host = RecordingPaneHost()
            let session = PaneSession(
                name: pane.sessionName, launch: launch, wantsForeground: true, reconnects: false,
                host: host, connect: { link.connection }
            )
            session.start()
            return Running(session: session, host: host)
        }

        struct Unexpected: Error {
            var answer: RemotePaneAnswer
        }
    }
}

extension RemotePaneAnswer {
    var isClose: Bool {
        if case .close = self { true } else { false }
    }

    func isWait(message expected: String?) -> Bool {
        if case let .wait(message) = self { message == expected } else { false }
    }
}

extension RemoteHosts.DeclineStore {
    static func memory() -> Self {
        let box = LockedBox<[String]>([])
        return .init(read: { box.value }, write: { value in box.mutate { $0 = value } })
    }
}
