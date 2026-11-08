import Darwin
import Foundation
@testable import Macterm
import Testing

@MainActor
struct SSHConnectionsTests {
    // MARK: - ControlPath

    @Test
    func the_user_control_path_comes_from_ssh_G() {
        let output = """
        user bob
        hostname example.com
        controlmaster auto
        controlpath /Users/bob/.ssh/cm-9dd075ce77cd1913d0c9b4f893e1395ac1183c8a
        controlpersist no
        """
        #expect(SSHControlPath.userPath(fromConfig: output) == "/Users/bob/.ssh/cm-9dd075ce77cd1913d0c9b4f893e1395ac1183c8a")
    }

    @Test
    func no_control_path_or_none_gives_nil() {
        #expect(SSHControlPath.userPath(fromConfig: "user bob\ncontrolmaster false\n") == nil)
        #expect(SSHControlPath.userPath(fromConfig: "controlpath none\n") == nil)
    }

    @Test
    func the_own_path_is_short_and_the_same_for_one_destination() {
        let directory = URL(fileURLWithPath: "/tmp/cm")
        let path = SSHControlPath.own(for: "bob@example.com", in: directory)
        #expect(path == SSHControlPath.own(for: "bob@example.com", in: directory))
        #expect(path != SSHControlPath.own(for: "alice@example.com", in: directory))
        #expect(path.hasPrefix("/tmp/cm/"))
        #expect((path as NSString).lastPathComponent.count == 16)
        #expect(SSHControlPath.fitsSocket(path))
        #expect(!SSHControlPath.fitsSocket("/" + String(repeating: "a", count: 90)))
    }

    @Test
    func a_destination_cannot_be_an_option_or_split() {
        #expect(SSHConnections.isValidDestination("bob@example.com"))
        #expect(SSHConnections.isValidDestination("devbox"))
        #expect(!SSHConnections.isValidDestination(""))
        #expect(!SSHConnections.isValidDestination("-oProxyCommand=evil"))
        #expect(!SSHConnections.isValidDestination("host other"))
        #expect(!SSHConnections.isValidDestination("host\nother"))
    }

    // MARK: - Askpass

    @Test
    func the_question_follows_the_prompt() {
        #expect(SSHLoginPrompts.Kind.of(prompt: "bob@box's password: ", confirm: false) == .secret)
        #expect(SSHLoginPrompts.Kind.of(
            prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            confirm: false
        ) == .yesNo)
        #expect(SSHLoginPrompts.Kind.of(prompt: "Allow use of key?", confirm: true) == .confirm)
    }

    @Test
    func the_shown_prompt_has_no_control_characters() {
        #expect(SSHLoginPrompts.displayText("pass\u{1B}[31mword: \u{7}") == "pass[31mword:")
        #expect(SSHLoginPrompts.displayText("line one\nline two") == "line one\nline two")
    }

    @Test
    func the_socket_names_the_peer_and_its_parent() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0])
            close(fds[1])
        }
        #expect(ControlSocketServer.peerPID(fds[0]) == getpid())
        #expect(ProcessInspector.parentPID(of: getpid()) == getppid())
    }

    @Test
    func an_askpass_that_no_connection_started_gets_no_answer() {
        let connections = SSHConnections(configuration: .init(controlDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))
        // This test process and its parent are no connections of Macterm.
        #expect(connections.askpassOwner(forPeer: getpid()) == nil)
        #expect(connections.askpassOwner(forPeer: getppid()) == nil)
    }

    // MARK: - Against a local sshd

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func two_commands_cost_one_login() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        defer { connections.disconnectAll() }

        let first = try await connections.run("box", "echo one")
        let second = try await connections.run("box", "echo two")
        #expect(first.status == 0)
        #expect(first.stdout == "one\n")
        #expect(second.stdout == "two\n")
        #expect(connections.logins["box"] == 1)
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_live_control_socket_of_the_user_is_used_and_no_login_happens() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let userPath = sshd.directory.appendingPathComponent("user-cm").path
        try sshd.addToConfig("ControlPath \(userPath)")
        let user = try sshd.startUsersOwnControl(controlPath: userPath)
        defer { user.terminate() }

        let connections = SSHConnections(configuration: sshd.configuration)
        defer { connections.disconnectAll() }
        let route = try await connections.connect("box")
        #expect(route == .init(controlPath: userPath, isUsersOwn: true))
        #expect(try await connections.run("box", "echo reused").stdout == "reused\n")
        #expect(connections.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func the_login_asks_its_askpass_for_a_passphrase() async throws {
        let sshd = try LocalSSHD(passphrase: "open sesame")
        defer { sshd.stop() }
        let log = sshd.directory.appendingPathComponent("askpass.log")
        let askpass = sshd.directory.appendingPathComponent("askpass")
        try "#!/bin/sh\necho \"$1\" >> '\(log.path)'\necho 'open sesame'\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        var configuration = sshd.configuration
        configuration.askpass = askpass.path

        let connections = SSHConnections(configuration: configuration)
        defer { connections.disconnectAll() }
        #expect(try await connections.run("box", "echo in").stdout == "in\n")
        let prompts = try String(contentsOf: log, encoding: .utf8)
        #expect(prompts.contains("passphrase"))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_refused_login_fails_and_a_command_never_logs_in_by_itself() async throws {
        let sshd = try LocalSSHD(passphrase: "right")
        defer { sshd.stop() }
        let askpass = sshd.directory.appendingPathComponent("askpass")
        try "#!/bin/sh\nexit 1\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        var configuration = sshd.configuration
        configuration.askpass = askpass.path

        let connections = SSHConnections(configuration: configuration)
        await #expect(throws: SSHConnections.Failure.self) { try await connections.run("box", "echo no") }
        #expect(connections.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 0)
    }
}

/// An sshd of this user on a free port of 127.0.0.1, with its own host key,
/// a key for the client, and an ssh config that names it `box`.
private struct LocalSSHD {
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    let directory: URL
    let port: UInt16
    let process: Process

    var configFile: URL { directory.appendingPathComponent("ssh_config") }
    var logFile: URL { directory.appendingPathComponent("sshd.log") }

    var configuration: SSHConnections.Configuration {
        SSHConnections.Configuration(
            ssh: ["/usr/bin/ssh"],
            options: ["-F", configFile.path],
            controlDirectory: directory.appendingPathComponent("cm"),
            askpass: nil
        )
    }

    init(passphrase: String = "") throws {
        // A short path: control sockets live under it.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mt-sshd-\(UInt32.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.keygen(directory.appendingPathComponent("host_key").path, passphrase: "")
        try Self.keygen(directory.appendingPathComponent("user_key").path, passphrase: passphrase)
        let authorized = directory.appendingPathComponent("authorized_keys")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("user_key.pub"), to: authorized)
        port = try Self.freePort()

        let sshdConfig = directory.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory.path)/host_key
        AuthorizedKeysFile \(authorized.path)
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        PidFile \(directory.path)/sshd.pid
        LogLevel INFO
        """.write(to: sshdConfig, atomically: true, encoding: .utf8)
        try """
        Host box
          HostName 127.0.0.1
          Port \(port)
          IdentityFile \(directory.path)/user_key
          IdentitiesOnly yes
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
          LogLevel ERROR

        """.write(to: directory.appendingPathComponent("ssh_config"), atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", sshdConfig.path, "-E", directory.appendingPathComponent("sshd.log").path]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !((try? String(contentsOf: directory.appendingPathComponent("sshd.log"), encoding: .utf8))?
            .contains("Server listening") ?? false)
        {
            guard Date() < deadline, process.isRunning else { throw CocoaError(.fileReadUnknown) }
            usleep(50000)
        }
    }

    func addToConfig(_ line: String) throws {
        let text = try String(contentsOf: configFile, encoding: .utf8)
        try (text.replacingOccurrences(of: "Host box\n", with: "Host box\n  \(line)\n"))
            .write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// A ControlMaster that the user started, outside Macterm.
    func startUsersOwnControl(controlPath: String) throws -> Process {
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = ["-F", configFile.path, "-M", "-N", "-S", controlPath, "box"]
        ssh.standardInput = FileHandle.nullDevice
        try ssh.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: controlPath) {
            guard Date() < deadline, ssh.isRunning else { throw CocoaError(.fileReadUnknown) }
            usleep(50000)
        }
        return ssh
    }

    func acceptedLogins() -> Int {
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return log.components(separatedBy: "\n").count { $0.contains("Accepted publickey") }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func keygen(_ path: String, passphrase: String) throws {
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-f", path]
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw CocoaError(.fileWriteUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
