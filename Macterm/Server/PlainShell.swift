import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PlainShell")

/// A plain ssh shell on a pty, for a remote pane on a host with no server
/// (`RemotePaneAnswer.plain`). The surface is a manual surface, so the app
/// runs the ssh itself: its output feeds the surface, and the surface's
/// input goes to its pty. There is no session: the shell stops when the
/// connection stops.
final class PlainShell: PaneInputRoute, @unchecked Sendable {
    private let primary: Int32
    private let pid: pid_t
    private let io = DispatchQueue(label: "PlainShell.write")
    private var reader: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// Read and written on `io` only.
    private var closed = false

    /// Starts `/usr/bin/ssh` (or the first argument, when it is a path)
    /// with `arguments` on a new pty of size `grid`. nil when it cannot.
    init?(arguments: [String], grid: PaneGrid, host: any PaneSessionHost, onExit: @escaping @Sendable (Int32) -> Void) {
        var size = winsize(
            ws_row: grid.rows,
            ws_col: grid.cols,
            ws_xpixel: UInt16(clamping: grid.widthPx),
            ws_ypixel: UInt16(clamping: grid.heightPx)
        )
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0, let first = arguments.first else { return nil }
        var secondaryName = [CChar](repeating: 0, count: 128)
        guard ttyname_r(secondaryFD, &secondaryName, secondaryName.count) == 0 else {
            close(primaryFD)
            close(secondaryFD)
            return nil
        }
        close(secondaryFD)
        _ = fcntl(primaryFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The session leader opens the slave with no O_NOCTTY, so it becomes
        // the controlling tty (ssh -t needs one).
        for descriptor in 0 ... 2 {
            posix_spawn_file_actions_addopen(&actions, Int32(descriptor), secondaryName, O_RDWR, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argv = arguments.map { strdup($0) } + [nil]
        defer {
            envp.forEach { free($0) }
            argv.forEach { free($0) }
        }
        let path = first.hasPrefix("/") ? first : "/usr/bin/\(first)"
        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            logger.error("plain shell: posix_spawn failed: \(status, privacy: .public)")
            close(primaryFD)
            return nil
        }
        primary = primaryFD
        pid = childPID

        let reader = DispatchSource.makeReadSource(fileDescriptor: primaryFD, queue: .global(qos: .userInitiated))
        reader.setEventHandler { [weak host] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(primaryFD, &buffer, buffer.count)
            if count > 0 { host?.paneFeed(Data(buffer[0 ..< count])) }
        }
        reader.resume()
        self.reader = reader
        let exit = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: .global(qos: .userInitiated))
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            self?.stop()
            onExit(status)
        }
        exit.resume()
        exitSource = exit
    }

    func sendInput(_ data: Data) {
        let primary = primary
        io.async {
            guard !self.closed else { return }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(primary, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }

    /// A plain shell has no leader: the surface's size is the pty's.
    func claim(grid: PaneGrid?) {
        sendSize(grid)
    }

    func sendSize(_ grid: PaneGrid?) {
        guard let grid else { return }
        let primary = primary
        io.async {
            guard !self.closed else { return }
            var size = winsize(
                ws_row: grid.rows,
                ws_col: grid.cols,
                ws_xpixel: UInt16(clamping: grid.widthPx),
                ws_ypixel: UInt16(clamping: grid.heightPx)
            )
            _ = ioctl(primary, TIOCSWINSZ, &size)
        }
    }

    /// Ends the shell: SIGHUP to its process group, as a closed terminal.
    func stop() {
        reader?.cancel()
        reader = nil
        exitSource?.cancel()
        exitSource = nil
        let primary = primary
        io.async {
            guard !self.closed else { return }
            self.closed = true
            close(primary)
        }
    }

    func terminate() {
        kill(pid, SIGHUP)
        stop()
    }
}
