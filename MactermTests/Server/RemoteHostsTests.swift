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
        #expect(await hosts.answer(.ask, session: "macterm-x-1", panes: []) == .close)
        // A local pane has no host.
        let local = Pane(projectPath: "/tmp", projectID: UUID())
        #expect(await hosts.answer(.ask, session: local.sessionName, panes: [local]) == .close)
    }

    // MARK: - Against a local sshd

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func one_login_serves_every_pane_and_the_host_foreground_reaches_the_pane() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let panes = (0 ..< 3).map { _ in fixture.pane() }
            var running: [PTYProcess] = []
            defer { running.forEach { $0.terminate() } }
            for pane in panes {
                let arguments = try await fixture.run(pane)
                let process = try PTYProcess(arguments)
                running.append(process)
                process.type("printf 'ready-%s\\n' \(pane.sessionName)\n")
                #expect(await process.wait(for: "ready-\(pane.sessionName)"))
                #expect(pane.hostSessionDirectory == fixture.directory)
            }
            #expect(host.sshd.acceptedLogins() == 1)
            #expect(host.connections.logins["box"] == 1)

            // The host pushes the foreground of the session into the pane's
            // output (`ZmxForegroundEvents`), so a program names the tab and
            // shows its logo with no probe.
            let first = running[0]
            first.type("sleep 30\n")
            #expect(await first.wait(for: "sleep 30\u{1B}\\"))
            let report = try #require(first.output.components(separatedBy: "\u{1B}_zmx;foreground;").last)
            #expect(report.hasPrefix("0;"))
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_dropped_link_waits_dimmed_and_heals_on_a_trigger() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            let first = try await PTYProcess(fixture.run(pane))
            defer { first.terminate() }
            first.type("printf 'before-%s\\n' drop\n")
            #expect(await first.wait(for: "before-drop"))

            // The link drops: the channel's ssh exits 255, and the client
            // reports it.
            host.sshd.dropConnections()
            #expect(await first.waitForExit() == 255)
            #expect(await fixture.hosts.answer(.lost, session: pane.sessionName, panes: [pane]) == .wait(message: nil))
            #expect(pane.isRemoteLinkLost)
            #expect(pane.isDisconnected)
            // No trigger yet: the pane keeps waiting.
            #expect(await fixture.hosts.answer(.ask, session: pane.sessionName, panes: [pane]) == .wait(message: nil))

            // A trigger wakes the pane; it logs in again and attaches to the
            // same session, which replays its screen.
            fixture.woken.removeAll()
            fixture.hosts.reconnect([pane.sessionName])
            #expect(fixture.woken == [RemoteHosts.wakeName(for: pane.sessionName)])
            let again = try await fixture.run(pane, clear: true)
            let second = try PTYProcess(again)
            defer { second.terminate() }
            #expect(await second.wait(for: "before-drop"))
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
            let first = try await PTYProcess(fixture.run(left))
            defer { first.terminate() }
            let second = try await PTYProcess(fixture.run(right))
            defer { second.terminate() }
            second.type("printf 'right-%s\\n' up\n")
            #expect(await second.wait(for: "right-up"))

            host.sshd.dropConnections()
            #expect(await first.waitForExit() == 255)
            #expect(await second.waitForExit() == 255)
            for pane in [left, right] {
                #expect(await fixture.hosts.answer(.lost, session: pane.sessionName, panes: [pane]) == .wait(message: nil))
                // Blurred: no line of Macterm's is on it.
                #expect(pane.isRemoteLinkLost && !pane.showsRemoteLinkMessage)
            }

            // A key in the left pane logs in again. The link that came back
            // is a trigger: the sweep wakes the right pane, which attaches
            // with no key and no second login.
            fixture.woken.removeAll()
            _ = try await fixture.run(left, event: .retry, clear: true)
            #expect(fixture.connected == ["box"])
            #expect(!fixture.woken.contains(RemoteHosts.wakeName(for: right.sessionName)))
            fixture.hosts.reconnect([right.sessionName])
            #expect(fixture.woken.contains(RemoteHosts.wakeName(for: right.sessionName)))
            let again = try await PTYProcess(fixture.run(right, clear: true))
            defer { again.terminate() }
            #expect(await again.wait(for: "right-up"))
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
            let first = try await PTYProcess(fixture.run(pane))
            first.type("printf 'up-%s\\n' 1\n")
            #expect(await first.wait(for: "up-1"))
            first.terminate()

            // The host restarts: its server and sessions are gone.
            try await host.stopServer()
            guard case let .ended(message) = await fixture.ask(pane) else {
                Issue.record("the pane did not ask")
                return
            }
            #expect(message.contains("ended"))
            // Return: a new shell in the same folder.
            // The new shell starts on an empty pane: the line goes.
            let arguments = try await fixture.run(pane, event: .create, clear: true)
            #expect(arguments.last?.contains("connect \"\(pane.sessionName)\" --") == true)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_mirror_that_asks_before_the_new_session_starts_makes_it_too() async throws {
        try await withSSHDHost { host in
            let fixture = Fixture(host)
            let pane = fixture.pane()
            _ = try await fixture.run(pane)
            #expect(pane.hostSessionDirectory == fixture.directory)
            // The first client has not started its ssh yet: the host has no
            // session. A second window's view of the pane asks now.
            let mirror = Pane(mirroring: pane)
            let arguments = try await fixture.run(mirror)
            #expect(arguments.last?.contains("connect \"\(pane.sessionName)\" --") == true)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(3)))
    func a_declined_server_gives_plain_shells_and_asks_once() async throws {
        try await withSSHDHost(answer: false) { host in
            let fixture = Fixture(host)
            for _ in 0 ..< 2 {
                let pane = fixture.pane()
                let answer = await fixture.settle(pane)
                guard case let .run(arguments, _, message) = answer else {
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
            hosts = RemoteHosts(connections: host.connections, servers: host.servers, configuration: configuration)
        }

        func pane() -> Pane {
            Pane(projectPath: "box:\(directory)", projectID: UUID())
        }

        /// The answer after the waits that a login or an install cause.
        func settle(_ pane: Pane, event: RemotePaneEvent = .ask) async -> RemotePaneAnswer {
            var answer = await hosts.answer(event, session: pane.sessionName, panes: [pane])
            let deadline = Date().addingTimeInterval(60)
            while answer == .wait(message: nil), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                answer = await hosts.answer(.ask, session: pane.sessionName, panes: [pane])
            }
            return answer
        }

        func ask(_ pane: Pane) async -> RemotePaneAnswer {
            await settle(pane)
        }

        /// The ssh that the pane's client runs.
        func run(_ pane: Pane, event: RemotePaneEvent = .ask, clear: Bool? = nil) async throws -> [String] {
            let answer = await settle(pane, event: event)
            guard case let .run(arguments, cleared, _) = answer else {
                throw Unexpected(answer: answer)
            }
            if let clear { #expect(cleared == clear) }
            return arguments
        }

        struct Unexpected: Error {
            var answer: RemotePaneAnswer
        }
    }
}

extension RemoteHosts.DeclineStore {
    static func memory() -> Self {
        let box = LockedBox<[String]>([])
        return .init(read: { box.value }, write: { value in box.mutate { $0 = value } })
    }
}
