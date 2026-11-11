import ArgumentParser
import Darwin
import Foundation
import notify

/// `macterm remote-pane`: the client on a remote pane's tty (0057). The
/// surface of a remote pane runs it, with the pane's session in
/// `MACTERM_SESSION`. It asks the app that started it (`MACTERM_SOCKET`,
/// `remote.pane`) what to do, and does it:
///
/// - `run`: run the ssh that the app gives on this tty, as a child, so a
///   lost connection (exit 255) does not end the pane. Any other exit is the
///   shell's: the client exits with it, and the pane closes.
/// - `wait`: wait for the app's Darwin notification (a reconnect trigger, a
///   login that ended) or a key, with the tty quiet. A key asks to connect
///   now.
/// - `ended`: the session is gone on the host. Wait for Return, then ask for
///   a new shell.
/// - `close`: the pane closed. Exit.
///
/// Requests are short: the app never holds a request while the user logs
/// in, and the wake says when to ask again.
struct RemotePaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-pane",
        abstract: "Connect a remote pane to its session. Macterm runs it; you do not.",
        shouldDisplay: false
    )

    /// The command that the surface resolved (login(1) and a shell) after
    /// the client, its command wrapper. The client never runs it.
    @Argument(parsing: .postTerminator, help: .hidden)
    var surfaceCommand: [String] = []

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment[ControlProtocol.sessionEnvVar], !session.isEmpty,
              let socket = environment[ControlProtocol.socketEnvVar], !socket.isEmpty
        else {
            Output.printError("macterm remote-pane runs only in a remote pane of Macterm")
            throw ExitCode(1)
        }
        var client = RemotePaneClient(session: session, client: ControlClient(socketOverride: socket, readTimeout: 30))
        throw ExitCode(client.run())
    }
}

struct RemotePaneClient {
    let session: String
    let client: ControlClient
    private var wake: Int32 = -1
    private var token: Int32 = 0
    private var original = termios()
    private var hasTTY = false
    /// Keys wake the wait only after the first ssh ran or a line asked for
    /// one. Before that, input stays for the shell: a layout's `run:` is
    /// typed into the pty at the start (`initial_input`), and ssh passes it
    /// on.
    private var keysWake = false
    /// Whether the cursor is at the start of a line: at the start, after a
    /// clear and after a line of the client. False after an ssh, which
    /// leaves the cursor where the session left it, often after a prompt.
    private var atLineStart = true

    init(session: String, client: ControlClient) {
        self.session = session
        self.client = client
    }

    /// The loop. Returns the exit status of the pane.
    mutating func run() -> Int32 {
        hasTTY = tcgetattr(STDIN_FILENO, &original) == 0
        // A key in the quiet wait is input, never a signal.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
        var event = "ask"
        var registered = false
        while true {
            let answer: ControlRemotePane
            switch ask(event) {
            case let .success(reply):
                answer = reply
            case let .failure(problem):
                // Never end the pane for a problem of the client: its exit
                // would end the session.
                show("macterm: \(problem.text). Press a key to try again.")
                event = waitForWakeOrKey() ? "retry" : "ask"
                continue
            }
            if !registered {
                registered = true
                register(answer.wake)
                // A wake posted before the registration is lost: ask again.
                if answer.action == "wait" {
                    event = "ask"
                    show(answer.message)
                    continue
                }
            }
            if answer.action == "run", answer.clear == true {
                write("\u{1B}[H\u{1B}[2J\u{1B}[3J")
                atLineStart = true
            }
            show(answer.message)
            switch answer.action {
            case "wait":
                event = waitForWakeOrKey() ? "retry" : "ask"
            case "run":
                guard let arguments = answer.arguments, !arguments.isEmpty else {
                    event = "ask"
                    continue
                }
                restoreTTY()
                keysWake = true
                let status = spawnAndWait(arguments)
                atLineStart = false
                // 255 is only a lost connection: the host's command passes
                // a shell's own 255 on as 254 (`RemoteSpawn.sessionCommand`).
                guard status == 255 else { return status }
                event = "lost"
            case "ended":
                event = waitForReturnOrWake() ? "create" : "ask"
            default:
                return 0
            }
        }
    }

    struct Problem: Error {
        var text: String
    }

    /// One `remote.pane` request. A Macterm that starts, or that does not
    /// answer for a moment, is asked again for a minute.
    private func ask(_ event: String) -> Result<ControlRemotePane, Problem> {
        var args = ControlArgs()
        args.session = session
        args.event = event
        let deadline = Date().addingTimeInterval(60)
        while true {
            if let response = try? client.send(command: "remote.pane", args: args) {
                if response.ok, let answer = response.data?.remotePane { return .success(answer) }
                if response.error?.code != .starting {
                    return .failure(Problem(text: response.error?.message ?? "Macterm did not answer"))
                }
            }
            guard Date() < deadline else { return .failure(Problem(text: "cannot reach Macterm")) }
            usleep(500_000)
        }
    }

    /// With no registration, the waits look again every few seconds.
    private mutating func register(_ name: String) {
        var fd: Int32 = -1
        guard notify_register_file_descriptor(name, &fd, 0, &token) == NOTIFY_STATUS_OK else { return }
        wake = fd
    }

    /// A line asks for a key, so keys wake the wait from then on. It starts
    /// on a line of its own.
    private mutating func show(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        keysWake = true
        write(ControlRemotePane.paneText(message, atLineStart: atLineStart))
        atLineStart = true
    }

    private func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            offset += count
        }
    }

    private enum Woken {
        case wake
        /// True for Return or a line end.
        case key(Bool)

        var isKey: Bool {
            if case .key = self { return true }
            return false
        }
    }

    /// True for a key, false for the wake.
    private func waitForWakeOrKey() -> Bool {
        guard keysWake else { return wait(keys: false).isKey }
        quietTTY()
        defer { restoreTTY() }
        return wait(keys: true).isKey
    }

    /// True for Return, false for the wake (a mirror of the pane started
    /// the new shell).
    private func waitForReturnOrWake() -> Bool {
        quietTTY()
        defer { restoreTTY() }
        while true {
            switch wait(keys: true) {
            case .wake: return false
            case let .key(isReturn) where isReturn: return true
            case .key: continue
            }
        }
    }

    /// Waits for the wake or, with `keys`, a key. A key that is Return or a
    /// line end says so. With no wake registered, it ends after 5 s.
    private func wait(keys: Bool) -> Woken {
        while true {
            var fds: [pollfd] = []
            if wake >= 0 { fds.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0)) }
            let tty = keys && hasTTY
            if tty { fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), wake >= 0 ? -1 : 5000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return .wake }
            if wake >= 0, fds[0].revents != 0 {
                drain(wake)
                return .wake
            }
            guard tty, let input = fds.last, input.revents != 0 else { continue }
            // The tty hung up: the pane closed.
            guard input.revents & Int16(POLLIN) != 0 else { exit(0) }
            let bytes = drain(STDIN_FILENO)
            if bytes.isEmpty { exit(0) }
            return .key(bytes.contains(0x0A) || bytes.contains(0x0D))
        }
    }

    /// Reads everything that waits on `fd`.
    @discardableResult
    private func drain(_ fd: Int32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 256)
        var all: [UInt8] = []
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            all += buffer[0 ..< count]
        }
        _ = fcntl(fd, F_SETFL, flags)
        return all
    }

    /// No echo, no line editing, no signals: a key wakes the wait and shows
    /// nothing.
    private func quietTTY() {
        guard hasTTY else { return }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutablePointer(to: &quiet.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    }

    private func restoreTTY() {
        guard hasTTY else { return }
        var saved = original
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    /// Run `arguments` on this tty and return its exit status. A signal
    /// ends it as a lost connection does (255), except a hangup: the pane
    /// closed, so the client ends too.
    private func spawnAndWait(_ arguments: [String]) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGINT, SIGQUIT, SIGTSTP, SIGPIPE] {
            sigaddset(&defaults, number)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, arguments[0], nil, &attributes, argv, environ)
        guard result == 0 else {
            Output.printError("cannot start \(arguments[0]): \(String(cString: strerror(result)))")
            return 255
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return 255 }
        }
        let low = status & 0x7F
        if low == 0 { return (status >> 8) & 0xFF }
        if low == SIGHUP { exit(0) }
        return 255
    }
}
