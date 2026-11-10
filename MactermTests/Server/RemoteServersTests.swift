import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteServersTests {
    // MARK: - The check's answer

    @Test
    func the_check_names_a_missing_server_with_or_without_a_host_id() {
        #expect(HostCheck.parse(status: 3, stderr: "macterm-host missing Linux x86_64 - 123\n")
            == .missing(.init(system: "Linux", machine: "x86_64", hostID: nil, hostKeys: "123")))
        #expect(HostCheck.parse(status: 3, stderr: "Warning: added\nmacterm-host missing Darwin arm64 1f2e-3d 456\n")
            == .missing(.init(system: "Darwin", machine: "arm64", hostID: "1f2e-3d", hostKeys: "456")))
        // A host id that is not one plain word is no host id: ask.
        #expect(HostCheck.parse(status: 3, stderr: "macterm-host missing Linux x86_64 a;b 123\n")
            == .missing(.init(system: "Linux", machine: "x86_64", hostID: nil, hostKeys: "123")))
        // Control characters from the host do not reach a log or an error.
        #expect(HostCheck.parse(status: 4, stderr: "macterm-host unsupported Plan\u{1B}[2J9 x\n")
            == .unsupported(system: "Plan[2J9", machine: "x"))
        #expect(HostCheck.parse(status: 4, stderr: "macterm-host no-home\n") == .noHome)
        #expect(HostCheck.parse(status: 4, stderr: "macterm-host unsupported FreeBSD amd64\n")
            == .unsupported(system: "FreeBSD", machine: "amd64"))
    }

    @Test
    func an_answer_that_is_not_the_scripts_is_no_check() {
        // ssh's own failure, and a status with no line of the script.
        #expect(HostCheck.parse(status: 255, stderr: "ssh: connect to host box port 22: Connection refused\n") == nil)
        #expect(HostCheck.parse(status: 3, stderr: "something else\n") == nil)
        #expect(HostCheck.parse(status: 0, stderr: "macterm-host missing Linux x86_64 - 123\n") == nil)
        #expect(HostCheck.parse(status: 3, stderr: "macterm-host missing Linux x86_64 -\n") == nil)
        #expect(HostCheck.parse(status: 3, stderr: "macterm-host no-home\n") == nil)
    }

    @Test
    func the_install_reports_the_host_id_it_keeps() {
        #expect(HostCheck.installedID(in: "macterm-host installed 1f2e-3d\n") == "1f2e-3d")
        #expect(HostCheck.installedID(in: "macterm-host installed \n") == nil)
        #expect(HostCheck.installedID(in: "installed 1f2e\n") == nil)
        #expect(HostCheck.reason(in: "macterm-host the checksum does not match\n") == "the checksum does not match")
    }

    // MARK: - Commands

    @Test
    func a_host_command_is_sh_c_with_plain_word_arguments() {
        #expect(HostScripts.command("echo $1", ["abc123"]) == "sh -c 'echo $1' macterm abc123")
        // Fail closed: nothing that a shell could split or quote.
        #expect(HostScripts.command("echo 'x'", ["abc"]) == nil)
        #expect(HostScripts.command("echo", ["a b"]) == nil)
        #expect(HostScripts.command("echo", ["a;rm"]) == nil)
        #expect(HostScripts.command("echo", [""]) == nil)
        #expect(HostScripts.command("echo", [String(repeating: "a", count: 65)]) == nil)
        // csh refuses a newline in single quotes, and reads `!x` as history.
        #expect(HostScripts.command("a\nb", ["abc"]) == nil)
        #expect(HostScripts.command("echo !x", ["abc"]) == nil)
        #expect(HostScripts.command("[ ! -e f ] && [ a != b ]", ["abc"]) != nil)
    }

    @Test
    func a_script_becomes_one_line_with_no_comments() {
        let script = "# note\nv=$1;\n\nif [ -n \"$v\" ]; then\n  echo x;  \nfi;\n"
        #expect(HostScripts.oneLine(script) == "v=$1; if [ -n \"$v\" ]; then echo x; fi;")
    }

    @Test
    func the_bundle_carries_the_host_scripts_of_the_tree() throws {
        let tree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/host", isDirectory: true)
        let scripts = try #require(HostScripts.load(from: tree))
        #expect(HostScripts.bundled == scripts, "Contents/Resources/host is not server/host: build again")
        let attach = try #require(scripts.attachCommand(key: "abc123"))
        let install = try #require(scripts.installCommand(key: "abc123", sha256: String(repeating: "f", count: 64), hostID: "id-1"))
        // Each line is valid sh, and the command parses with csh as the
        // login shell (here as the arguments of `true`).
        for (script, command) in [(scripts.attach, attach), (scripts.install, install)] {
            #expect(Self.status("/bin/sh", ["-n", "-c", script]) == 0, "not valid sh: \(script)")
            #expect(Self.status("/bin/csh", ["-f", "-c", "true " + command.dropFirst("sh -c ".count)]) == 0)
        }
    }

    private static func status(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Rules

    @Test
    func an_older_server_makes_way_and_a_newer_one_stays() {
        func hello(level: UInt32, build: String) -> MactermProtocol.Hello {
            .init(level: level, minLevel: 1, build: build, role: .server, epoch: 1, caps: [])
        }
        let ours = MactermProtocol.level
        let other = hello(level: ours, build: "1.0.1+thdxg.def")
        #expect(!RemoteServers.shouldReplace(hello(level: ours, build: "1.0.1+thdxg.abc"), key: "abc", installed: true))
        // Another build of the same level: only after this connect installed.
        #expect(RemoteServers.shouldReplace(other, key: "abc", installed: true))
        #expect(!RemoteServers.shouldReplace(other, key: "abc", installed: false))
        #expect(RemoteServers.shouldReplace(hello(level: ours, build: "unknown"), key: "abc", installed: true))
        #expect(!RemoteServers.shouldReplace(hello(level: ours + 1, build: "1.0.1+thdxg.def"), key: "abc", installed: true))
    }

    @Test
    func a_consent_holds_only_for_the_same_destination_host_id_and_host_keys() {
        func host(_ id: String?, _ keys: String = "123") -> HostCheck.Missing {
            .init(system: "Linux", machine: "x86_64", hostID: id, hostKeys: keys)
        }
        let consents = ["me@box:22": "id-1 123"]
        #expect(RemoteServers.consented(consents, destination: "me@box:22", host: host("id-1")))
        #expect(!RemoteServers.consented(consents, destination: "me@box:22", host: host("id-2")))
        #expect(!RemoteServers.consented(consents, destination: "me@box:22", host: host("id-1", "999")))
        #expect(!RemoteServers.consented(consents, destination: "me@box:22", host: host(nil)))
        #expect(!RemoteServers.consented(consents, destination: "me@other:22", host: host("id-1")))
        // `ssh -G` failed: ask.
        #expect(!RemoteServers.consented(consents, destination: nil, host: host("id-1")))
    }

    @Test
    func the_resolved_destination_comes_from_ssh_G() {
        let output = "user me\nhostname 10.0.0.5\nport 2222\nuser other\n"
        #expect(SSHControlPath.resolvedDestination(fromConfig: output) == "me@10.0.0.5:2222")
        #expect(SSHControlPath.resolvedDestination(fromConfig: "user me\nport 22\n") == nil)
    }

    // MARK: - Against a local sshd

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(2)))
    func the_first_install_asks_once_and_a_current_host_costs_one_command() async throws {
        try await withHost { host in
            let link = try await host.servers.connect("box")
            #expect(link.installed)
            #expect(link.connection.serverHello.build.hasSuffix("+thdxg.\(host.key)"))
            #expect(host.asked == ["box"])
            let file = host.home.appendingPathComponent(".local/share/macterm/bin/macterm-\(host.key)")
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
            #expect(try FileManager.default.destinationOfSymbolicLink(
                atPath: host.home.appendingPathComponent(".local/bin/macterm").path
            ) == file.path)
            let hostID = try String(
                contentsOf: host.home.appendingPathComponent(".local/share/macterm/host-id"), encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(host.consents.values.map { $0.split(separator: " ").first.map(String.init) } == [hostID])
            link.close()

            let again = try await host.servers.connect("box")
            #expect(!again.installed)
            #expect(again.commands == 1)
            #expect(host.asked.count == 1)
            again.close()
            #expect(host.sshd.acceptedLogins() == 1)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(2)))
    func a_cancel_installs_nothing() async throws {
        try await withHost(answer: false) { host in
            await #expect(throws: RemoteServers.Failure.declined) { try await host.servers.connect("box") }
            #expect(host.asked.count == 1)
            #expect(!FileManager.default.fileExists(atPath: host.home.appendingPathComponent(".local").path))
            #expect(host.consents.isEmpty)
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(2)))
    func a_changed_host_id_asks_again_and_the_same_one_does_not() async throws {
        try await withHost { host in
            try await host.servers.connect("box").close()
            let share = host.home.appendingPathComponent(".local/share/macterm")
            try await host.stopServer()

            // The same host lost its server file: its id is the one that the
            // user allowed. No question.
            try FileManager.default.removeItem(at: share.appendingPathComponent("bin"))
            let same = try await host.servers.connect("box")
            #expect(same.installed)
            #expect(host.asked.count == 1)
            same.close()
            try await host.stopServer()

            // Another machine with Macterm's files: another host id.
            try FileManager.default.removeItem(at: share.appendingPathComponent("bin"))
            try "other-id\n".write(to: share.appendingPathComponent("host-id"), atomically: true, encoding: .utf8)
            let changed = try await host.servers.connect("box")
            #expect(changed.installed)
            #expect(host.asked.count == 2)
            changed.close()
            try await host.stopServer()

            // The name now reaches another machine: no files, no host id.
            try FileManager.default.removeItem(at: share)
            let other = try await host.servers.connect("box")
            #expect(other.installed)
            #expect(host.asked.count == 3)
            other.close()
        }
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(2)))
    func an_update_replaces_the_server_and_keeps_old_sessions() async throws {
        try await withHost { host in
            let first = try await host.servers.connect("box")
            let oldEpoch = first.connection.serverHello.epoch
            _ = try await first.connection.call(MactermProtocol.SessionCreate.self, .init(
                id: "old",
                command: ["/bin/sleep", "600"].map { ProtocolBin(Data($0.utf8)) },
                cols: 80,
                rows: 24
            ))
            first.close()

            // A newer app: another build key. The same binary stands for the
            // new build, so its hello still names the old key, and the app
            // replaces the server once.
            let newer = try host.servers(key: "eeee0000")
            let link = try await newer.connect("box")
            #expect(link.installed)
            #expect(link.connection.serverHello.epoch != oldEpoch)
            #expect(host.asked.count == 1)
            let sessions = try await link.connection.call(MactermProtocol.SessionList.self, .init()).sessions
            #expect(sessions.map(\.id) == ["old"])
            #expect(sessions.first?.state == .running)
            link.close()
            let bin = host.home.appendingPathComponent(".local/share/macterm/bin")
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: bin.path)) == ["macterm-\(host.key)", "macterm-eeee0000"])

            // The first app again: its file is there, so it installs nothing
            // and uses the server of the later install, as it is.
            let back = try await host.servers.connect("box")
            #expect(!back.installed)
            #expect(back.commands == 1)
            #expect(back.connection.serverHello.epoch == link.connection.serverHello.epoch)
            back.close()
        }
    }

    // MARK: - Fixture

    /// A host on a local sshd, with its own home and runtime folder, and the
    /// app's bundled builds and scripts.
    @MainActor
    private final class Host {
        let sshd: LocalSSHD
        let home: URL
        let runtime: URL
        let connections: SSHConnections
        let key: String
        let answer: Bool
        private let builds: URL
        private(set) var asked: [String] = []
        var consents: [String: String] = [:]
        private(set) lazy var servers = makeServers(ServerBuilds.bundled)

        init(answer: Bool) async throws {
            let key = try #require(ServerBuilds.bundled.key, "no bundled server: run mise run setup")
            _ = try #require(await ServerBuilds.bundled.build(for: .macOS))
            let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("mt-host-\(UInt32.random(in: 0 ... .max))")
            home = root.appendingPathComponent("home")
            runtime = root.appendingPathComponent("run")
            builds = root.appendingPathComponent("builds")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
            sshd = try LocalSSHD(sshdOptions: ["SetEnv HOME=\(home.path) MACTERM_RUNTIME_DIR=\(runtime.path)"])
            connections = SSHConnections(configuration: sshd.configuration)
            self.key = key
            self.answer = answer
        }

        func servers(key: String) throws -> RemoteServers {
            let source = try #require(ServerBuilds.bundled.key.map {
                Bundle.main.resourceURL!.appendingPathComponent("server/macterm-\($0)-universal-macos.gz")
            })
            try FileManager.default.copyItem(at: source, to: builds.appendingPathComponent("macterm-\(key)-universal-macos.gz"))
            return makeServers(ServerBuilds(key: key, directory: builds))
        }

        private func makeServers(_ builds: ServerBuilds) -> RemoteServers {
            RemoteServers(connections: connections, configuration: .init(
                scripts: HostScripts.bundled,
                builds: builds,
                askConsent: { [unowned self] host in
                    asked.append(host)
                    return answer
                },
                consents: .init(read: { [unowned self] in consents }, write: { [unowned self] in consents = $0 })
            ))
        }

        /// Ends the host's server and its sessions, as a host that restarted.
        func stopServer() async throws {
            let path = runtime.appendingPathComponent(".server").path
            guard FileManager.default.fileExists(atPath: path),
                  let connection = try? ServerConnection.connect(path: path)
            else { return }
            for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
                _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
            }
            _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
            connection.close()
        }

        func stop() async {
            try? await stopServer()
            await connections.disconnect("box")
            sshd.stop()
            try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        }
    }

    private func withHost(answer: Bool = true, _ body: (Host) async throws -> Void) async throws {
        let host = try await Host(answer: answer)
        do {
            try await body(host)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }
}
