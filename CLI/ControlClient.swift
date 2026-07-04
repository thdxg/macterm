import Foundation

/// CLI-side of the control socket: discovery, connection, one
/// request/response round-trip. Synchronous by design — the CLI has nothing
/// else to do while it waits.
struct ControlClient {
    /// Explicit `--socket` value: a hard pin, tried alone.
    var socketOverride: String?

    struct ClientError: Error, CustomStringConvertible {
        var description: String
        /// True when no socket answered at all (app not running) — exit 2.
        var isConnectionFailure: Bool
    }

    /// Send one request and return the decoded response.
    func send(command: String, args: ControlArgs? = nil) throws -> ControlResponse {
        let request = ControlRequest(command: command, args: args)
        let payload = try ControlProtocol.encode(request)

        var attempts: [String] = []
        for path in candidatePaths() {
            switch tryPath(path, payload: payload) {
            case let .success(raw):
                let response: ControlResponse
                do {
                    response = try ControlProtocol.decodeResponse(raw)
                } catch {
                    throw ClientError(
                        description: "undecodable response from \(path): \(error.localizedDescription)",
                        isConnectionFailure: false
                    )
                }
                guard response.id == request.id else {
                    throw ClientError(
                        description: "response id mismatch from \(path)",
                        isConnectionFailure: false
                    )
                }
                return response
            case let .failure(reason):
                attempts.append("  \(path): \(reason)")
            }
        }
        let hint = socketOverride == nil
            ? "\nIs Macterm running? (launch it, or pass --socket for a non-default location)"
            : ""
        throw ClientError(
            description: "could not reach Macterm's control socket:\n" + attempts.joined(separator: "\n") + hint,
            isConnectionFailure: true
        )
    }

    /// Discovery order: explicit `--socket` is a hard pin (tried alone);
    /// otherwise the `MACTERM_SOCKET` env hint first — but only as a *hint*:
    /// a stale exported path (app restarted since this shell spawned) falls
    /// through to the well-known per-flavor locations instead of bricking
    /// the CLI in that shell (cmux's documented sleep/wake trap).
    func candidatePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let override = socketOverride, !override.isEmpty {
            return [override]
        }
        var paths: [String] = []
        if let hinted = environment[ControlProtocol.socketEnvVar], !hinted.isEmpty {
            paths.append(hinted)
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        for flavor in ["Macterm", "Macterm Debug"] {
            paths.append(
                appSupport
                    .appendingPathComponent(flavor, isDirectory: true)
                    .appendingPathComponent(ControlProtocol.socketFilename)
                    .path
            )
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    // MARK: - One connection attempt

    private enum Attempt {
        case success(Data)
        case failure(String)
    }

    private func tryPath(_ path: String, payload: Data) -> Attempt {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return .failure("no socket file")
        }
        // Refuse sockets owned by another user — a planted socket at a
        // predictable path must not receive our commands.
        guard st.st_uid == getuid() else {
            return .failure("not owned by the current user; refusing to connect")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure("socket(): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            return .failure("path exceeds sun_path limit")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { dstPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    dstPtr.update(from: srcBase, count: src.count)
                }
            }
        }

        // Non-blocking connect + short poll: a dead socket file (app crashed,
        // listener gone) fails in ~250ms instead of hanging the CLI.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                return .failure(String(cString: strerror(errno)))
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, 250) > 0, pollFD.revents & Int16(POLLERR | POLLHUP) == 0 else {
                return .failure("connect timed out")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else {
                return .failure(String(cString: strerror(soError)))
            }
        }
        // Back to blocking for the write/read; bound the read instead.
        _ = fcntl(fd, F_SETFL, flags)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard writeAll(fd: fd, data: payload) else {
            return .failure("write failed: \(String(cString: strerror(errno)))")
        }
        // Half-close: tells the server the request is complete.
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0 ..< n])
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .failure("timed out waiting for a response")
                }
                return .failure("read failed: \(String(cString: strerror(errno)))")
            }
        }
        guard !data.isEmpty else {
            return .failure("connection closed without a response")
        }
        return .success(data)
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    if errno == EINTR { continue }
                    return false
                }
            }
            return true
        }
    }
}
