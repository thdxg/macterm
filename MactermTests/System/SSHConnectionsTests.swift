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
    func a_new_host_key_shows_its_type_and_fingerprint() throws {
        let prompt = """
        The authenticity of host 'localhost (::1)' can't be established.
        ED25519 key fingerprint is SHA256:Hx4kP3o0aB+cdEf/ghIjkLmNoPqRsTuVwXyZ0123456.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(SSHLoginPrompts.hostKey(in: prompt))
        #expect(key.host == "localhost (::1)")
        #expect(key.type == "ED25519")
        #expect(key.fingerprint == "SHA256:Hx4kP3o0aB+cdEf/ghIjkLmNoPqRsTuVwXyZ0123456")
        #expect(SSHLoginPrompts.hostKey(in: "bob@box's password:") == nil)
        // No host line: the sheet cannot say whose key it is.
        #expect(SSHLoginPrompts.hostKey(in: "ED25519 key fingerprint is SHA256:abc.") == nil)
    }

    @Test
    func a_new_host_key_from_openssh_10_5_has_a_colon_after_is() throws {
        // The text of OpenSSH 10.5 in the VM (UI review of PR 745).
        let prompt = """
        The authenticity of host 'localhost (::1)' can't be established.
        ED25519 key fingerprint is: SHA256:+5/x06NnIxLuUAhlw-D7oo5lEV3KR37gqnojrjti4mV0
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(SSHLoginPrompts.hostKey(in: prompt))
        #expect(key.host == "localhost (::1)")
        #expect(key.type == "ED25519")
        #expect(key.fingerprint == "SHA256:+5/x06NnIxLuUAhlw-D7oo5lEV3KR37gqnojrjti4mV0")
    }

    @Test
    func a_retry_is_the_same_prompt_from_the_same_ssh() {
        let passphrase = "Enter passphrase for key '/Users/bob/.ssh/id_ed25519': "
        let jump = SSHLoginPrompts.Request(host: "prod", prompt: passphrase, kind: .secret, sshPID: 100, askerPID: 200)
        let destination = SSHLoginPrompts.Request(host: "prod", prompt: passphrase, kind: .secret, sshPID: 100, askerPID: 100)
        let answered = [jump.asker: passphrase]
        #expect(SSHLoginPrompts.isRetry(jump, answered: answered))
        // The destination asks the same text after the jump host: not a retry.
        #expect(!SSHLoginPrompts.isRetry(destination, answered: answered))
        #expect(!SSHLoginPrompts.isRetry(jump, answered: [:]))
    }

    @Test
    func macterm_knows_a_question_only_by_the_exact_openssh_text() {
        typealias Question = SSHLoginPrompts.Question
        #expect(Question.of("bob@box's password: ", kind: .secret) == .password(account: "bob@box"))
        #expect(Question.of("(bob@box) Password: ", kind: .secret) == .password(account: "bob@box"))
        #expect(Question.of("Enter passphrase for key '/tmp/id_ed25519': ", kind: .secret) == .passphrase(key: "/tmp/id_ed25519"))
        let home = NSHomeDirectory()
        #expect(Question.of("Enter passphrase for key '\(home)/.ssh/id': ", kind: .secret) == .passphrase(key: "~/.ssh/id"))
        // Any other text is unknown, also when it has a known word.
        #expect(Question.of("Verification code: ", kind: .secret) == .unknown(line: "Verification code:"))
        #expect(Question.of("New password: ", kind: .secret) == .unknown(line: "New password:"))
        #expect(Question.of("Password for bob: ", kind: .secret) == .unknown(line: "Password for bob:"))
        #expect(Question.of("Allow use of key?", kind: .confirm) == .unknown(line: "Allow use of key?"))
    }

    @Test
    func an_unknown_question_shows_only_its_prompt_line() {
        let prompt = "Duo two-factor login for bob\n\nEnter a passcode or select one of the following options:\n\n"
            + "Passcode or option (1-3): \u{1B}"
        #expect(SSHLoginPrompts.Question.of(prompt, kind: .secret).text == "Passcode or option (1-3):")
        let yesNo = "Warning: the ECDSA host key for 'box' differs from the key for the IP address.\n"
            + "Are you sure you want to continue connecting (yes/no)?"
        #expect(SSHLoginPrompts.Question.of(yesNo, kind: .yesNo).text == "Are you sure you want to continue connecting (yes/no)?")
    }

    @Test
    func a_refusal_names_only_what_macterm_knows() {
        #expect(SSHLoginPrompts.Question.passphrase(key: "k").refusal == "The passphrase is incorrect.")
        #expect(SSHLoginPrompts.Question.password(account: "bob@box").refusal == "The password is incorrect.")
        #expect(SSHLoginPrompts.Question.unknown(line: "Verification code:").refusal == "The answer is incorrect.")
    }

    // MARK: - Notice

    @Test
    func a_login_that_asks_nothing_shows_its_last_line_after_the_delay() {
        var notice = SSHLoginNotice()
        let start = ContinuousClock.now
        let text = "\nTo authenticate, visit:\n\n\thttps://login.example.test/a/1\n\n"
        #expect(notice.update(text: text, asking: false, now: start) == nil)
        #expect(notice.update(text: text, asking: false, now: start + .milliseconds(1900)) == nil)
        #expect(notice.update(text: text, asking: false, now: start + SSHLoginNotice.delay) == "https://login.example.test/a/1")
        // A new line waits the delay again.
        let more = text + "Still waiting\n"
        #expect(notice.update(text: more, asking: false, now: start + .seconds(3)) == nil)
        #expect(notice.update(text: more, asking: false, now: start + .seconds(5)) == "Still waiting")
    }

    @Test
    func text_before_a_question_and_ssh_warnings_show_no_notice() {
        var notice = SSHLoginNotice()
        let start = ContinuousClock.now
        let banner = "Authorized use only.\n"
        _ = notice.update(text: banner, asking: false, now: start)
        #expect(notice.update(text: banner, asking: true, now: start + .seconds(1)) == nil)
        // After the question, the banner is old text.
        #expect(notice.update(text: banner, asking: false, now: start + .seconds(9)) == nil)
        let warned = banner + "Warning: Permanently added 'box' (ED25519) to the list of known hosts.\n"
        _ = notice.update(text: warned, asking: false, now: start + .seconds(10))
        #expect(notice.update(text: warned, asking: false, now: start + .seconds(20)) == nil)
    }

    @Test
    func a_notice_links_only_an_https_url() {
        #expect(SSHLoginPrompts.link(in: "To authenticate, visit: https://login.example.test/a/1.")?.absoluteString
            == "https://login.example.test/a/1")
        #expect(SSHLoginPrompts.link(in: "Go to http://example.test/x") == nil)
        #expect(SSHLoginPrompts.link(in: "Waiting for the host") == nil)
        #expect(SSHLoginPrompts.link(in: "see https:// now") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func a_login_that_waits_on_a_link_reports_it_until_it_ends() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mt-notice-\(UInt32.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A stand-in ssh: no config, no master, and a login that writes a
        // link and waits, as a host that waits for a log-in in the browser.
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        case " $* " in
          *" -M "*) echo 'To authenticate, visit: https://example.test/x' >&2; exec sleep 30 ;;
          *) exit 255 ;;
        esac

        """.write(to: ssh, atomically: true, encoding: .utf8)
        chmod(ssh.path, 0o700)
        let connections = SSHConnections(configuration: .init(ssh: [ssh.path], controlDirectory: directory.appendingPathComponent("cm")))
        var reports: [String?] = []
        connections.onLoginNotice = { host, _, line in
            #expect(host == "box")
            reports.append(line)
        }
        let login = Task { try await connections.connect("box") }
        while reports.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reports == ["To authenticate, visit: https://example.test/x"])
        connections.disconnect("box")
        await #expect(throws: SSHConnections.Failure.self) { try await login.value }
        #expect(reports == ["To authenticate, visit: https://example.test/x", nil])
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
    func a_control_directory_with_a_space_works() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        var configuration = sshd.configuration
        // As "Macterm Debug" in Application Support.
        configuration.controlDirectory = sshd.directory.appendingPathComponent("M D", isDirectory: true)
        let connections = SSHConnections(configuration: configuration)
        defer { connections.disconnectAll() }

        let route = try await connections.connect("box")
        #expect(route.controlPath.contains("M D/"))
        #expect(try await connections.run("box", "echo spaced").stdout == "spaced\n")
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func one_cancel_ends_the_login() async throws {
        let sshd = try LocalSSHD(passphrase: "open sesame")
        defer { sshd.stop() }
        let pidFile = sshd.directory.appendingPathComponent("askpass.pid")
        let askpass = sshd.directory.appendingPathComponent("askpass")
        // It waits for an answer that never comes, as a sheet up on screen.
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nsleep 30\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        var configuration = sshd.configuration
        configuration.askpass = askpass.path

        let connections = SSHConnections(configuration: configuration)
        defer { connections.disconnectAll() }
        defer {
            // The fake askpass outlives its master.
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                kill(pid, SIGKILL)
            }
        }
        let login = Task { try await connections.connect("box") }
        var owner: (host: String, pid: pid_t)?
        for _ in 0 ..< 100 where owner == nil {
            try await Task.sleep(for: .milliseconds(100))
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            owner = pid.flatMap { connections.askpassOwner(forPeer: $0) }
        }
        let connection = try #require(owner).pid
        connections.cancelLogin(connectionPID: connection)
        await #expect(throws: SSHConnections.Failure.cancelled) { try await login.value }
        #expect(kill(connection, 0) != 0)
        #expect(connections.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 0)
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

    @Test
    func the_peer_must_run_the_bundled_askpass() throws {
        let own = try #require(ProcessInspector.executablePath(pid: getpid()))
        #expect(SSHConnections.process(getpid(), runs: own))
        #expect(!SSHConnections.process(getpid(), runs: "/bin/ls"))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func the_askpass_of_a_login_belongs_to_its_connection() async throws {
        let sshd = try LocalSSHD(passphrase: "open sesame")
        defer { sshd.stop() }
        let pidFile = sshd.directory.appendingPathComponent("askpass.pid")
        let go = sshd.directory.appendingPathComponent("go")
        let askpass = sshd.directory.appendingPathComponent("askpass")
        // It waits until the test has looked at it, as the real one waits
        // for the user.
        try """
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        i=0
        while [ ! -e '\(go.path)' ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        echo 'open sesame'

        """.write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        var configuration = sshd.configuration
        // As in the app: ssh through env, so the pid chain is the same.
        configuration.ssh = ["/usr/bin/env", "ssh"]
        configuration.askpass = askpass.path

        let connections = SSHConnections(configuration: configuration)
        defer { connections.disconnectAll() }
        let login = Task { try await connections.connect("box") }
        var pid: pid_t?
        for _ in 0 ..< 100 where pid == nil {
            try await Task.sleep(for: .milliseconds(100))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let askpassPID = try #require(pid)
        #expect(connections.askpassOwner(forPeer: askpassPID)?.host == "box")
        #expect(connections.askpassOwner(forPeer: getpid()) == nil)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        _ = try await login.value
        #expect(connections.logins["box"] == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_refused_login_fails_and_counts_no_login() async throws {
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
