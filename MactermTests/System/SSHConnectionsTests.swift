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
    func the_own_path_is_short_and_follows_where_the_config_sends_the_host() {
        let directory = URL(fileURLWithPath: "/tmp/cm")
        let config = "user bob\nhostname example.com\nport 22\ncontrolpersist no\n"
        let path = SSHControlPath.own(forConfig: config, in: directory)
        // Keys that do not change the endpoint do not change the path.
        #expect(path == SSHControlPath.own(forConfig: config + "serveraliveinterval 60\n", in: directory))
        #expect(path != SSHControlPath.own(forConfig: "user alice\nhostname example.com\nport 22\n", in: directory))
        #expect(path != SSHControlPath.own(forConfig: "user bob\nhostname example.com\nport 2222\n", in: directory))
        #expect(path != SSHControlPath.own(forConfig: config + "proxyjump bastion\n", in: directory))
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
    }

    @Test
    func a_yes_no_question_that_macterm_does_not_know_keeps_the_lines_above_it() {
        // A security question fails closed: the host and the key stay in view.
        let changed = "Warning: the ECDSA host key for 'box' differs from the key for the IP address.\n"
            + "Are you sure you want to continue connecting (yes/no)?"
        #expect(SSHLoginPrompts.Question.of(changed, kind: .yesNo)
            == .unknown(line: "Warning: the ECDSA host key for 'box' differs from the key for the IP address."))
        // A host-key text in a form that the parser does not read.
        let future = "The authenticity of host 'box (1.2.3.4)' can't be established.\n"
            + "ED25519 key fingerprint, SHA256:abc\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        #expect(SSHLoginPrompts.Question.of(future, kind: .yesNo)
            == .unknown(line: "The authenticity of host 'box (1.2.3.4)' can't be established.\nED25519 key fingerprint, SHA256:abc"))
        #expect(SSHLoginPrompts.Question.of("Continue (yes/no)?", kind: .yesNo) == .unknown(line: "Continue (yes/no)?"))
    }

    @Test
    func a_password_prompt_needs_an_account_with_a_host() {
        #expect(SSHLoginPrompts.Question.of("root's password: ", kind: .secret) == .unknown(line: "root's password:"))
        #expect(SSHLoginPrompts.Question.of("@box's password: ", kind: .secret) == .unknown(line: "@box's password:"))
        #expect(SSHLoginPrompts.Question.of("a b@box's password: ", kind: .secret) == .unknown(line: "a b@box's password:"))
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
            + "** WARNING: connection is not using a post-quantum key exchange algorithm.\n"
            + "** The server may need to be upgraded. See https://openssh.com/pq.html\n"
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
        #expect(SSHLoginPrompts.link(in: "Open <https://example.test/y>.")?.absoluteString == "https://example.test/y")
        #expect(SSHLoginPrompts.link(in: "(https://example.test/z)")?.absoluteString == "https://example.test/z")
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
          *" -G "*) echo 'hostname box'; exit 0 ;;
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
        await connections.disconnect("box")
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
        let route = try await connections.connect("box")
        #expect(route == .init(controlPath: userPath, isUsersOwn: true))
        #expect(try await connections.run("box", "echo reused").stdout == "reused\n")
        #expect(connections.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_config_change_ends_only_the_own_connection_and_never_the_users() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        let own = try await connections.connect("box")

        let userPath = sshd.directory.appendingPathComponent("user-cm").path
        try sshd.addToConfig("ControlPath \(userPath)")
        let user = try sshd.startUsersOwnControl(controlPath: userPath)
        defer { user.terminate() }
        try sshd.addToConfig("HostName localhost")

        #expect(try await connections.connect("box") == .init(controlPath: userPath, isUsersOwn: true))
        #expect(!FileManager.default.fileExists(atPath: own.controlPath))
        await connections.endStaleConnections()
        await connections.disconnect("box")
        #expect(user.isRunning)
        #expect(FileManager.default.fileExists(atPath: userPath))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_connection_that_two_destinations_share_ends_only_with_the_last() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        // The same user, host and port: one path.
        let other = "\(NSUserName())@box"
        let route = try await connections.connect("box")
        #expect(try await connections.connect(other) == route)

        await connections.disconnect("box")
        #expect(FileManager.default.fileExists(atPath: route.controlPath))
        #expect(try await connections.run(other, "echo shared").stdout == "shared\n")
        #expect(sshd.acceptedLogins() == 1)

        await connections.disconnect(other)
        #expect(!FileManager.default.fileExists(atPath: route.controlPath))
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
        #expect(try await connections.run("box", "echo in").stdout == "in\n")
        let prompts = try String(contentsOf: log, encoding: .utf8)
        #expect(prompts.contains("passphrase"))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_quit_and_a_new_launch_log_in_once() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let first = SSHConnections(configuration: sshd.configuration)
        #expect(try await first.run("box", "echo one").stdout == "one\n")
        first.endLogins()

        // The next launch finds the master on the same path.
        let second = SSHConnections(configuration: sshd.configuration)
        #expect(try await second.run("box", "echo two").stdout == "two\n")
        #expect(second.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_changed_config_does_not_use_the_connection_of_an_earlier_run() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let first = SSHConnections(configuration: sshd.configuration)
        let old = try await first.connect("box")
        first.endLogins()

        // ssh takes the first value: the host now has another name.
        try sshd.addToConfig("HostName localhost")
        let second = SSHConnections(configuration: sshd.configuration)
        let new = try await second.connect("box")
        #expect(new.controlPath != old.controlPath)
        #expect(second.logins["box"] == 1)
        #expect(sshd.acceptedLogins() == 2)
        // The old master is Macterm's, so it ends.
        #expect(!FileManager.default.fileExists(atPath: old.controlPath))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_config_change_while_macterm_runs_logs_in_again_and_ends_the_old_connection() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        let old = try await connections.connect("box")

        try sshd.addToConfig("HostName localhost")
        let new = try await connections.connect("box")
        #expect(new.controlPath != old.controlPath)
        #expect(connections.logins["box"] == 2)
        #expect(!FileManager.default.fileExists(atPath: old.controlPath))
        #expect(try await connections.run("box", "echo new").stdout == "new\n")
        #expect(sshd.acceptedLogins() == 2)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_launch_ends_a_connection_that_the_config_no_longer_gives() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let first = SSHConnections(configuration: sshd.configuration)
        let old = try await first.connect("box")
        first.endLogins()

        try sshd.addToConfig("HostName localhost")
        let second = SSHConnections(configuration: sshd.configuration)
        await second.endStaleConnections()
        #expect(!FileManager.default.fileExists(atPath: old.controlPath))
        #expect(second.logins["box"] == nil)
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_launch_keeps_a_connection_that_the_config_still_gives() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let first = SSHConnections(configuration: sshd.configuration)
        let route = try await first.connect("box")
        first.endLogins()

        let second = SSHConnections(configuration: sshd.configuration)
        await second.endStaleConnections()
        #expect(FileManager.default.fileExists(atPath: route.controlPath))
        #expect(try await second.run("box", "echo kept").stdout == "kept\n")
        #expect(sshd.acceptedLogins() == 1)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_config_that_ssh_cannot_read_ends_the_connection() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let first = SSHConnections(configuration: sshd.configuration)
        let route = try await first.connect("box")
        first.endLogins()

        try sshd.addToConfig("Port not-a-number")
        let second = SSHConnections(configuration: sshd.configuration)
        await second.endStaleConnections()
        #expect(!FileManager.default.fileExists(atPath: route.controlPath))
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func a_dropped_link_ends_the_connection_and_the_next_command_logs_in() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        let route = try await connections.connect("box")

        sshd.dropConnections()
        let deadline = ContinuousClock.now + .seconds(10)
        while FileManager.default.fileExists(atPath: route.controlPath), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: route.controlPath))
        #expect(try await connections.run("box", "echo back").stdout == "back\n")
        #expect(connections.logins["box"] == 2)
        #expect(sshd.acceptedLogins() == 2)
    }

    @Test(.enabled(if: LocalSSHD.isAvailable), .timeLimit(.minutes(1)))
    func disconnect_ends_the_connection() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connections = SSHConnections(configuration: sshd.configuration)
        let route = try await connections.connect("box")
        await connections.disconnect("box")
        #expect(!FileManager.default.fileExists(atPath: route.controlPath))
        _ = try await connections.connect("box")
        #expect(connections.logins["box"] == 2)
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
