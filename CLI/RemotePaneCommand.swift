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
        while true {
            guard let answer = ask(event) else { return 1 }
            if wake < 0 {
                guard register(answer.wake) else { return 1 }
                // A wake posted before the registration is lost: ask again.
                if answer.action == "wait" {
                    event = "ask"
                    show(answer.message)
                    continue
                }
            }
            show(answer.message)
            switch answer.action {
            case "wait":
                event = waitForWakeOrKey() ? "retry" : "ask"
            case "run":
                guard let arguments = answer.arguments, !arguments.isEmpty else { return 1 }
                if answer.clear == true { write("\u{1B}[H\u{1B}[2J\u{1B}[3J") }
                restoreTTY()
                let status = spawnAndWait(arguments)
                guard status == 255 else { return status }
                event = "lost"
            case "ended":
                waitForReturn()
                event = "create"
            default:
                return 0
            }
        }
    }

    /// One `remote.pane` request. A Macterm that starts, or that does not
    /// answer for a moment, is asked again for a minute.
    private func ask(_ event: String) -> ControlRemotePane? {
        var args = ControlArgs()
        args.session = session
        args.event = event
        let deadline = Date().addingTimeInterval(60)
        while true {
            if let response = try? client.send(command: "remote.pane", args: args) {
                if response.ok, let answer = response.data?.remotePane { return answer }
                if response.error?.code != .starting {
                    Output.printError(response.error?.message ?? "Macterm did not answer")
                    return nil
                }
            }
            guard Date() < deadline else {
                Output.printError("cannot reach Macterm")
                return nil
            }
            usleep(500_000)
        }
    }

    private mutating func register(_ name: String) -> Bool {
        var fd: Int32 = -1
        guard notify_register_file_descriptor(name, &fd, 0, &token) == NOTIFY_STATUS_OK else {
            Output.printError("cannot wait for Macterm")
            return false
        }
        wake = fd
        return true
    }

    private func show(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        write(message + "\n")
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

    /// True for a key, false for the wake.
    private func waitForWakeOrKey() -> Bool {
        quietTTY()
        defer { restoreTTY() }
        while true {
            var fds = [pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            if hasTTY { fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)) }
            guard poll(&fds, nfds_t(fds.count), -1) >= 0 else {
                if errno == EINTR { continue }
                return false
            }
            if fds[0].revents != 0 {
                drain(wake)
                return false
            }
            if fds.count > 1, fds[1].revents & Int16(POLLIN) != 0 {
                drain(STDIN_FILENO)
                return true
            }
            if fds.count > 1, fds[1].revents != 0 {
                // The tty hung up: the pane closed.
                exit(0)
            }
        }
    }

    private func waitForReturn() {
        guard hasTTY else { return }
        quietTTY()
        defer { restoreTTY() }
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { exit(0) }
            if byte == 0x0A || byte == 0x0D { return }
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        while read(fd, &buffer, buffer.count) > 0 {}
        _ = fcntl(fd, F_SETFL, flags)
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
