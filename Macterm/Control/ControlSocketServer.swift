import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ControlSocketServer")

/// App-side listener for the `macterm` control CLI. Accepts one request per
/// connection on a Unix-domain socket, reads a newline-terminated JSON line
/// (the client half-closes after sending), and hands it to the attached
/// `@MainActor` handler, whose JSON response is written back before close.
///
/// The accept loop runs on its own thread against a NON-BLOCKING listen
/// socket polled every 20ms — never a blocking `accept()` on a queue shared
/// with `stop()`, which would starve shutdown behind the block. Each accepted
/// connection is read on a concurrent connection queue (OFF the accept thread,
/// so a slow client can't stall accepting the next one), then dispatch hops to
/// the main actor via a Task that owns the fd from then on.
///
/// Started at app launch, before AppState exists; requests arriving before
/// `attach(handler:)` get a `starting` error so a fast CLI poll (e.g. the
/// benchmark harness waiting for readiness) sees a well-formed response
/// instead of a hang.
final class ControlSocketServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (Data) async -> Data

    private let socketPath: String
    /// Guards `listenFD`, `isRunning`, and `handler` — touched by the control
    /// methods (main thread) and the accept thread.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var handler: Handler?
    private var acceptThread: Thread?
    /// Per-connection reads run here, OFF the accept thread, so one slow client
    /// can't block the accept loop (and every other pending control request)
    /// for up to the SO_RCVTIMEO backstop. Concurrent so multiple in-flight
    /// connections read in parallel.
    private let connectionQueue = DispatchQueue(
        label: "com.thdxg.macterm.control-connection",
        attributes: .concurrent
    )

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The path exported to spawned shells via `MACTERM_SOCKET`.
    var path: String { socketPath }

    /// The per-flavor well-known socket location (`Macterm/` vs
    /// `Macterm Debug/`, or the benchmark's `MACTERM_BENCHMARK_DATA_DIR`).
    static func defaultSocketPath() -> String {
        FileStorage.fileURL(filename: ControlProtocol.socketFilename).path
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        guard bindAndListen() else { return }
        isRunning = true
        logger.info("control socket listening at \(self.socketPath, privacy: .public)")
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.thdxg.macterm.control-socket"
        thread.stackSize = 512 * 1024
        acceptThread = thread
        thread.start()
    }

    /// Wire up request dispatch once AppState/ProjectStore exist (the server
    /// itself starts earlier, at applicationDidFinishLaunching).
    func attach(handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func stop() {
        // Signal shutdown but do NOT close the listen fd from this thread while
        // the accept thread may still be mid-syscall on it — a close here could
        // race the accept loop's read-fd-then-accept sequence, and the fd number
        // could be reused by an unrelated open() in the window. The accept loop
        // polls `running` every 20ms, so it observes the flag and closes its own
        // fd on exit. Join it so stop() doesn't return before teardown lands.
        lock.lock()
        isRunning = false
        let thread = acceptThread
        let neverStarted = listenFD < 0
        lock.unlock()

        if let thread, !neverStarted {
            // Bounded wait for the accept thread to notice the flag and exit.
            // (Thread has no join; poll its `isFinished`.)
            let deadline = Date().addingTimeInterval(1.0)
            while !thread.isFinished, Date() < deadline {
                usleep(5000)
            }
        }
        // Fallback: if the accept thread never ran (bind failed) or didn't
        // finish in time, close from here — there's no live syscall to race.
        lock.lock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
        lock.unlock()
        unlink(socketPath)
    }

    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private var currentListenFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listenFD
    }

    private var currentHandler: Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    // MARK: - Socket setup

    private func bindAndListen() -> Bool {
        // Ensure the parent dir exists and any stale socket (crashed previous
        // run) is gone before binding.
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        // sun_path is a fixed ~104-byte C array; refuse overlong paths rather
        // than truncate (a truncated bind would listen somewhere else).
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            logger.error("socket path too long (\(pathBytes.count, privacy: .public) > \(maxLen, privacy: .public))")
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { dstPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    dstPtr.update(from: srcBase, count: src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return false
        }
        // Same-user only: filesystem permissions are the auth boundary.
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            logger.error("listen() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return false
        }
        // Non-blocking listen socket: the accept loop polls and re-checks
        // `running`, so `stop()` takes effect within one poll tick.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // Shells spawned by the app must not inherit the listen fd — a
        // long-lived child holding it would keep the socket alive past quit.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd
        return true
    }

    private func acceptLoop() {
        // The accept thread OWNS the listen fd's final close (see `stop()`):
        // closing it here, on the thread that issues accept() on it, removes the
        // cross-thread close-vs-syscall race entirely.
        defer {
            lock.lock()
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            lock.unlock()
        }
        while running {
            let fd = currentListenFD
            guard fd >= 0 else { break }
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(20000) // 20ms; bounds stop() latency without busy-wait
                    continue
                }
                if running {
                    logger.error("accept() failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                break
            }
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            // Darwin propagates the listen socket's O_NONBLOCK to accepted fds
            // (verified empirically; contrary to POSIX/Linux). Clear it so the
            // SO_RCVTIMEO-bounded blocking read/write below behave as intended —
            // otherwise a read racing the client's payload gets EAGAIN, which
            // the read loop would treat as a fatal empty request, and a full
            // send buffer would silently truncate the response.
            let cflags = fcntl(clientFD, F_GETFL, 0)
            if cflags >= 0 { _ = fcntl(clientFD, F_SETFL, cflags & ~O_NONBLOCK) }
            // A disappeared client must surface as EPIPE on write, not a
            // process-killing SIGPIPE.
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Backstop read timeout — the client half-closes right after
            // sending, so a stalled read means a broken client.
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Read + dispatch OFF the accept thread so a slow client doesn't
            // stall accepting the next connection. The queue closure owns the
            // fd from here.
            connectionQueue.async { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    // MARK: - Per-connection handling

    /// Read the request on the connection queue (off the accept thread), then
    /// hand the fd to a `@MainActor` task for dispatch and response. The task
    /// owns the fd from then on.
    private func handleConnection(_ fd: Int32) {
        guard let raw = Self.readAll(fd: fd), !raw.isEmpty else {
            Self.write(fd: fd, data: ControlProtocol.encode(.failure(
                id: "",
                error: ControlError(code: .badRequest, message: "empty or unreadable request")
            )))
            close(fd)
            return
        }
        guard let handler = currentHandler else {
            // Echo the request id when it parses so the client can correlate.
            let id = (try? ControlProtocol.decodeRequest(raw))?.id ?? ""
            Self.write(fd: fd, data: ControlProtocol.encode(.failure(
                id: id,
                error: ControlError(
                    code: .starting,
                    message: "Macterm is still starting up",
                    action: "retry in a moment"
                )
            )))
            close(fd)
            return
        }
        Task { @MainActor in
            let response = await handler(raw)
            Self.write(fd: fd, data: response)
            close(fd)
        }
    }

    // MARK: - Socket IO

    /// Upper bound on a single request so a client that streams without ever
    /// half-closing can't balloon memory. Control requests are tiny JSON lines;
    /// 1 MiB is orders of magnitude of headroom.
    private static let maxRequestBytes = 1 << 20

    /// Read until EOF (the client half-closes its write end after sending).
    /// Returns accumulated bytes on EOF or on a SO_RCVTIMEO timeout (EAGAIN on
    /// the now-blocking fd) so a partial-but-present request still parses; nil
    /// only on a genuine read error or when the size cap is exceeded.
    private static func readAll(fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0 ..< n])
                if data.count > maxRequestBytes {
                    logger.error("control request exceeded \(maxRequestBytes, privacy: .public) bytes; dropping")
                    return nil
                }
            } else if n == 0 {
                return data
            } else {
                if errno == EINTR { continue }
                // SO_RCVTIMEO fired (blocking fd) — return whatever arrived so
                // a complete-but-not-yet-half-closed request still dispatches.
                if errno == EAGAIN || errno == EWOULDBLOCK { return data }
                return nil
            }
        }
    }

    private static func write(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    if errno == EINTR { continue }
                    break
                }
            }
        }
    }
}
