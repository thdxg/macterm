import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteServersConnectTests {
    /// Connects to one host wait for each other. A waiter that saw the
    /// finished task before its owner cleaned up spun on the main actor for
    /// ever (0206).
    @Test
    func concurrent_connects_to_one_host_all_end() async {
        let servers = RemoteServers(
            connections: SSHConnections(configuration: .init(
                controlDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            )),
            configuration: .init(
                scripts: nil,
                builds: ServerBuilds(key: nil, directory: nil),
                askConsent: { _ in false },
                consents: .init(read: { [:] }, write: { _ in })
            )
        )
        let tasks = (0 ..< 20).map { _ in
            Task { @MainActor in
                do {
                    _ = try await servers.connect("nobody@host.invalid", login: false)
                    return false
                } catch RemoteServers.Failure.notBundled {
                    return true
                } catch {
                    return false
                }
            }
        }
        var failures = 0
        for task in tasks where await task.value {
            failures += 1
        }
        #expect(failures == 20)
    }
}
