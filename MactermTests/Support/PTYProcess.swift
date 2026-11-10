import Darwin
import Foundation

/// A program on a pty of its own, as a pane's surface runs one: a new
/// session whose controlling terminal is the pty. The test reads everything
/// that the program writes, and types into it.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let primary: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var exitStatus: Int32?

    init(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primary, TIOCSWINSZ, &size)
        let terminalPath = String(cString: name)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened after setsid, so the pty becomes the controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, terminalPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(primary)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        self.pid = pid
        self.primary = primary
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in waitLoop() }
    }

    var output: String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }

    var status: Int32? {
        lock.withLock { exitStatus }
    }

    func type(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(primary, $0.baseAddress, $0.count) }
    }

    /// Waits until the output holds `text`. False after `timeout`.
    func wait(for text: String, timeout: TimeInterval = 20) async -> Bool {
        await poll(timeout: timeout) { self.output.contains(text) }
    }

    /// Waits until the program exits, and returns its status.
    func waitForExit(timeout: TimeInterval = 20) async -> Int32? {
        _ = await poll(timeout: timeout) { self.status != nil }
        return status
    }

    /// Ends the program and closes the pty.
    func terminate() {
        kill(pid, SIGHUP)
        kill(pid, SIGKILL)
        close(primary)
    }

    private func poll(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(primary, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            lock.withLock { buffer.append(contentsOf: chunk[0 ..< count]) }
        }
    }

    private func waitLoop() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        lock.withLock { exitStatus = code }
    }
}
