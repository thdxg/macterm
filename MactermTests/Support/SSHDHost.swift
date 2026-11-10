import Foundation
@testable import Macterm
import Testing

/// A host on a local sshd, with its own home and runtime folder, and the
/// app's bundled builds and scripts.
@MainActor
final class SSHDHost {
    let sshd: LocalSSHD
    let home: URL
    let runtime: URL
    let connections: SSHConnections
    let key: String
    let answer: Bool
    private let builds: URL
    private(set) var asked: [String] = []
    var consents: [String: String] = [:]
    private(set) lazy var servers = makeServers(ServerBuilds.bundled)

    init(answer: Bool) async throws {
        let key = try #require(ServerBuilds.bundled.key, "no bundled server: run mise run setup")
        _ = try #require(await ServerBuilds.bundled.build(for: .macOS))
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("mt-host-\(UInt32.random(in: 0 ... .max))")
        home = root.appendingPathComponent("home")
        runtime = root.appendingPathComponent("run")
        builds = root.appendingPathComponent("builds")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        // SHELL: the login shell of a session on the host, the same for
        // every user who runs the tests.
        sshd = try LocalSSHD(sshdOptions: ["SetEnv HOME=\(home.path) MACTERM_RUNTIME_DIR=\(runtime.path) SHELL=/bin/sh"])
        connections = SSHConnections(configuration: sshd.configuration)
        self.key = key
        self.answer = answer
    }

    func servers(key: String) throws -> RemoteServers {
        let source = try #require(ServerBuilds.bundled.key.map {
            Bundle.main.resourceURL!.appendingPathComponent("server/macterm-\($0)-universal-macos.gz")
        })
        try FileManager.default.copyItem(at: source, to: builds.appendingPathComponent("macterm-\(key)-universal-macos.gz"))
        return makeServers(ServerBuilds(key: key, directory: builds))
    }

    private func makeServers(_ builds: ServerBuilds) -> RemoteServers {
        RemoteServers(connections: connections, configuration: .init(
            scripts: HostScripts.bundled,
            builds: builds,
            askConsent: { [unowned self] host in
                asked.append(host)
                return answer
            },
            consents: .init(read: { [unowned self] in consents }, write: { [unowned self] in consents = $0 })
        ))
    }

    /// Ends the host's server and its sessions, as a host that restarted.
    func stopServer() async throws {
        let path = runtime.appendingPathComponent(".server").path
        guard FileManager.default.fileExists(atPath: path),
              let connection = try? ServerConnection.connect(path: path)
        else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }

    func stop() async {
        try? await stopServer()
        await connections.disconnect("box")
        sshd.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }
}

@MainActor
func withSSHDHost(answer: Bool = true, _ body: (SSHDHost) async throws -> Void) async throws {
    let host = try await SSHDHost(answer: answer)
    do {
        try await body(host)
    } catch {
        await host.stop()
        throw error
    }
    await host.stop()
}
