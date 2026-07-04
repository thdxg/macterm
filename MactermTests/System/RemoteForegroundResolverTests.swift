import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteForegroundResolverTests {
    private func remotePane(host: String = "devbox") -> Pane {
        Pane(projectPath: "\(host):~/dev/api", projectID: UUID())
    }

    /// Let the resolver's fire-and-forget apply Task run.
    private func flush() async {
        for _ in 0 ..< 4 {
            await Task.yield()
        }
    }

    // MARK: - Probe output parsing

    @Test
    func parses_session_tab_comm_lines() {
        let out = """
        macterm-api-abc123\tbtop
        macterm-api-def456\t/usr/local/bin/hx
        garbage line
        supa-other\tvim
        macterm-empty\t
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-abc123": "btop",
            "macterm-api-def456": "/usr/local/bin/hx",
        ])
    }

    // MARK: - Cadence gate

    @Test
    func probes_once_per_host_within_the_interval() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let probe: @Sendable (ProjectPath) async -> [String: String]? = { spec in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return [:]
        }
        let panes = [remotePane(), remotePane()]
        let t0 = Date()

        resolver.refresh(panes: panes, probe: probe, now: t0)
        resolver.refresh(panes: panes, probe: probe, now: t0.addingTimeInterval(1))
        await flush()
        #expect(calls.value == ["devbox"])

        resolver.refresh(panes: panes, probe: probe, now: t0.addingTimeInterval(4))
        await flush()
        #expect(calls.value == ["devbox", "devbox"])
    }

    @Test
    func distinct_hosts_probe_independently_in_one_pass() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        resolver.refresh(panes: [remotePane(host: "alpha"), remotePane(host: "beta")], probe: { spec in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return [:]
        })
        await flush()
        #expect(Set(calls.value) == ["alpha", "beta"])
    }

    // MARK: - Name application

    @Test
    func applies_probe_names_to_matching_panes() async {
        let pane = remotePane()
        let resolver = RemoteForegroundResolver(minInterval: 0)
        let session = pane.sessionName
        resolver.refresh(panes: [pane], probe: { _ in [session: "btop"] })
        await flush()
        #expect(pane.foregroundProcessName == "btop")
    }

    @Test
    func failed_probe_keeps_last_known_names() async {
        let pane = remotePane()
        pane.applyRemoteForegroundName("btop")
        let resolver = RemoteForegroundResolver(minInterval: 0)
        resolver.refresh(panes: [pane], probe: { _ in nil })
        await flush()
        // Silent degradation: the name froze instead of flapping to nil.
        #expect(pane.foregroundProcessName == "btop")
    }
}
