import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ServerConnection")

/// One connection to the local server's channel 0 (design/003 §1, §4): the
/// handshake, requests and their responses, and the server's events.
///
/// A thread of its own reads the socket. A request waits for its response,
/// matched by id. When the connection ends, every waiting request fails with
/// `ServerClientError.disconnected` and `events` finishes. The reader holds
/// the connection until the connection ends: call `close()` when done.
final class ServerConnection: @unchecked Sendable {
    /// The server's `hello`.
    let serverHello: MactermProtocol.Hello
    /// The server's pid, from the socket's peer. Nil when the kernel did not
    /// say.
    let serverPID: pid_t?
    /// One element for each event batch, in order. A batch is one consistent
    /// state: apply all of it at once (design/003 §5).
    let events: AsyncStream<[ServerEvent]>

    private let fd: Int32
    private let eventSink: AsyncStream<[ServerEvent]>.Continuation
    private let lock = NSLock()
    /// Held for each write and for the close, so that no write goes to an
    /// fd number that the close gave back to the system.
    private let fdLock = NSLock()
    private var fdIsOpen = true
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MactermProtocol.Response, Error>] = [:]
    private var isClosed = false

    /// How long the handshake waits for the server's `hello`.
    static let handshakeTimeout: TimeInterval = 5

    /// Connects to the socket at `path` and does the handshake as the GUI.
    /// Throws `ServerClientError.noAnswer` when nothing listens there, or
    /// when the server closes before its `hello` (it exits when idle). It
    /// blocks: call it off the main thread.
    static func connect(path: String) throws -> ServerConnection {
        let fd = try openSocket(path: path)
        return try handshake(fd: fd, peerPID: peerPID(fd), timeout: handshakeTimeout)
    }

    /// Does the handshake as the GUI on `fd`, a connected stream socket: the
    /// local server's socket, or one end of a socket pair whose other end is
    /// the stdio of a host's `macterm proxy` (`RemoteServers`). The
    /// connection owns `fd` from here, and closes it on a failure too.
    /// `peerPID` is the server's pid, when the kernel names it. It blocks:
    /// call it off the main thread.
    static func handshake(fd: Int32, peerPID: pid_t?, timeout: TimeInterval) throws -> ServerConnection {
        do {
            var reader = FrameReader(fd: fd)
            setReceiveTimeout(fd, seconds: timeout)
            let mine = MactermProtocol.Hello(
                level: MactermProtocol.level,
                minLevel: MactermProtocol.minLevel,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                role: .gui,
                epoch: 0,
                caps: []
            )
            try write(fd, ProtocolControl.hello(mine))
            // The server sends its `hello` at the accept. When it refuses
            // this build, a `refuse` follows after our `hello`: the same
            // check is done here, from its `min_level`.
            let theirs: MactermProtocol.Hello
            do {
                guard case let .hello(hello) = try ProtocolControl.decode(reader.next().body) else {
                    throw ServerClientError.protocolError
                }
                theirs = hello
            } catch ServerClientError.disconnected {
                throw ServerClientError.noAnswer
            }
            guard mine.level >= theirs.minLevel else {
                throw ServerClientError.refused(needsLevel: theirs.minLevel)
            }
            guard min(mine.level, theirs.level) >= MactermProtocol.minLevel else {
                try? write(fd, ProtocolControl.refuse(.init(reason: "level_too_low", needsLevel: MactermProtocol.minLevel)))
                throw ServerClientError.serverTooOld(level: theirs.level)
            }
            setReceiveTimeout(fd, seconds: 0)
            let connection = ServerConnection(fd: fd, hello: theirs, pid: peerPID)
            connection.startReading(reader)
            return connection
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private init(fd: Int32, hello: MactermProtocol.Hello, pid: pid_t?) {
        self.fd = fd
        serverHello = hello
        serverPID = pid
        (events, eventSink) = AsyncStream.makeStream(of: [ServerEvent].self)
    }

    /// Sends one request and waits for its response. A response with `err`
    /// throws `ProtocolControlError.errorResponse`.
    func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args) async throws -> M.Result {
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MactermProtocol.Response, Error>) in
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                continuation.resume(throwing: ServerClientError.disconnected)
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = continuation
            lock.unlock()
            do {
                try send(.request(MactermProtocol.Request(id: id, method: method, args: args)))
            } catch {
                lock.lock()
                let waiting = pending.removeValue(forKey: id)
                lock.unlock()
                waiting?.resume(throwing: error)
            }
        }
        return try response.result(of: method)
    }

    /// Ends the connection. Requests that wait fail with `disconnected`.
    func close() {
        // The reader thread closes the fd when its read ends.
        fdLock.lock()
        if fdIsOpen { Darwin.shutdown(fd, SHUT_RDWR) }
        fdLock.unlock()
        finish()
    }

    private func send(_ message: ProtocolControl) throws {
        fdLock.lock()
        defer { fdLock.unlock() }
        guard fdIsOpen else { throw ServerClientError.disconnected }
        try Self.write(fd, message)
    }

    private func startReading(_ reader: FrameReader) {
        let thread = Thread { [self] in
            var reader = reader
            while true {
                do {
                    let frame = try reader.next()
                    try handle(ProtocolControl.decode(frame.body))
                } catch {
                    if case ServerClientError.disconnected = error {} else {
                        logger.error("server connection: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }
            finish()
            fdLock.lock()
            fdIsOpen = false
            Darwin.close(fd)
            fdLock.unlock()
        }
        thread.name = "ServerConnection"
        thread.start()
    }

    private func handle(_ message: ProtocolControl) throws {
        switch message {
        case let .response(response):
            lock.lock()
            let waiting = pending.removeValue(forKey: response.re)
            lock.unlock()
            waiting?.resume(returning: response)
        case let .events(batch):
            let events = batch.ev.compactMap(ServerEvent.init)
            if !events.isEmpty { eventSink.yield(events) }
        case .hello,
             .request,
             .refuse:
            throw ServerClientError.protocolError
        case .unknown:
            break
        }
    }

    private func finish() {
        lock.lock()
        isClosed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: ServerClientError.disconnected)
        }
        eventSink.finish()
    }
}

/// An event of the server that this build reads. Events that a later build
/// added are skipped.
enum ServerEvent: Equatable {
    /// A session's shell exited. The session keeps the status until a client
    /// sends `session.kill`.
    case sessionExit(MactermProtocol.SessionExit)

    init?(_ event: MactermProtocol.Event) {
        switch event.e {
        case MactermProtocol.SessionExit.name:
            guard let value = try? event.a?.decode(MactermProtocol.SessionExit.self) else { return nil }
            self = .sessionExit(value)
        default:
            return nil
        }
    }
}

enum ServerClientError: Error, Equatable {
    /// Nothing listens on the socket.
    case noAnswer
    /// `macterm server` did not start. The text is its error output.
    case startFailed(String)
    /// The server refuses this build: its level is under the server's
    /// lowest. Update Macterm.
    case refused(needsLevel: UInt32)
    /// The server speaks a level under this build's lowest.
    case serverTooOld(level: UInt32)
    /// The server sent a message that has no place here.
    case protocolError
    /// The connection ended.
    case disconnected
}

// MARK: - Socket

extension ServerConnection {
    private static func openSocket(path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw ServerClientError.noAnswer }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerClientError.noAnswer }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw ServerClientError.noAnswer
        }
        return fd
    }

    private static func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The pid of the process on the other end (`LOCAL_PEERPID`).
    private static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    private static func write(_ fd: Int32, _ message: ProtocolControl) throws {
        guard let body = message.encoded() else { return }
        let data = try ProtocolFrame(channel: ProtocolFrame.controlChannel, kind: .msg, body: body).encoded()
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ServerClientError.disconnected
                }
                offset += written
            }
        }
    }
}

/// Reads whole frames from a socket. Only channel 0 comes from the server.
private struct FrameReader {
    let fd: Int32
    var buffer = Data()

    mutating func next() throws -> ProtocolFrame {
        while true {
            if let (frame, length) = try ProtocolFrame.parse(buffer) {
                buffer.removeFirst(length)
                return frame
            }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ServerClientError.disconnected }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }
}
