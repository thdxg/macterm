import Foundation
@testable import Macterm
import Testing

/// Exercises the real Unix socket end to end against a temp path — bind,
/// connect, request/response framing, and lifecycle hygiene. The "client"
/// here is a minimal raw-socket writer so these tests cover the server
/// contract independently of the CLI's `ControlClient`.
@MainActor
struct ControlSocketServerTests {
    private func makeSocketPath() -> String {
        // Keep it short: sun_path caps at ~104 bytes and the default tempdir
        // path can be long.
        "/tmp/macterm-test-\(UInt32.random(in: 0 ..< UInt32.max)).sock"
    }

    /// Run the raw round-trip off the main actor so the server's MainActor
    /// response task can execute while the client blocks on read.
    private func awaitResponse(path: String, line: Data) async -> Data? {
        let payload = line
        return await Task.detached {
            roundTripDetached(path: path, line: payload)
        }.value
    }

    // MARK: - Lifecycle

    @Test
    func start_creates_socket_and_stop_unlinks_it() {
        let path = makeSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.start()
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func start_is_idempotent_and_replaces_a_stale_socket_file() {
        let path = makeSocketPath()
        // Simulate a crashed previous run: a dead socket file at the path.
        FileManager.default.createFile(atPath: path, contents: nil)
        let server = ControlSocketServer(socketPath: path)
        server.start()
        server.start() // second start is a no-op, not a rebind
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func stop_before_start_is_safe() {
        let server = ControlSocketServer(socketPath: makeSocketPath())
        server.stop()
    }

    // MARK: - Request handling

    @Test
    func request_before_attach_gets_starting_error_echoing_id() async throws {
        let path = makeSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.start()
        defer { server.stop() }

        var request = ControlRequest(command: "status")
        request.id = "early-bird"
        let raw = try #require(await awaitResponse(path: path, line: ControlProtocol.encode(request)))
        let response = try ControlProtocol.decodeResponse(raw)
        #expect(!response.ok)
        #expect(response.error?.code == .starting)
        #expect(response.id == "early-bird")
    }

    @Test
    func attached_handler_round_trips_a_response() async throws {
        let path = makeSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.start()
        defer { server.stop() }
        server.attach { raw in
            let request = (try? ControlProtocol.decodeRequest(raw))
            return ControlProtocol.encode(.success(
                id: request?.id ?? "",
                data: ControlData(status: ControlStatusInfo(
                    version: "test", pid: 7, activeProject: nil, activeProjectID: nil
                ))
            ))
        }

        let request = ControlRequest(command: "status")
        let raw = try #require(await awaitResponse(path: path, line: ControlProtocol.encode(request)))
        let response = try ControlProtocol.decodeResponse(raw)
        #expect(response.ok)
        #expect(response.id == request.id)
        #expect(response.data?.status?.version == "test")
    }

    @Test
    func empty_request_gets_bad_request() async throws {
        let path = makeSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.start()
        defer { server.stop() }

        let raw = try #require(await awaitResponse(path: path, line: Data()))
        let response = try ControlProtocol.decodeResponse(raw)
        #expect(response.error?.code == .badRequest)
    }

    @Test
    func overlong_socket_path_refuses_to_start() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let server = ControlSocketServer(socketPath: path)
        server.start()
        #expect(!FileManager.default.fileExists(atPath: path))
        server.stop()
    }

    @Test
    func default_socket_path_lives_in_app_support() {
        let path = ControlSocketServer.defaultSocketPath()
        #expect(path.hasSuffix("/" + ControlProtocol.socketFilename))
    }
}

/// Free function so the detached task doesn't capture the MainActor test
/// struct. Mirrors the private helper above.
private func roundTripDetached(path: String, line: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= maxLen else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { dstPtr in
            bytes.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                dstPtr.update(from: base, count: src.count)
            }
        }
    }
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    if !line.isEmpty {
        let sent = line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return write(fd, base, line.count) == line.count
        }
        guard sent else { return nil }
    }
    shutdown(fd, SHUT_WR)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 { data.append(contentsOf: buffer[0 ..< n]) } else { break }
    }
    return data
}
