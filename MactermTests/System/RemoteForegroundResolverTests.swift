import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteForegroundResolverTests {
    private func remotePane(host: String = "devbox") -> Pane {
        Pane(projectPath: "\(host):~/dev/api", projectID: UUID())
    }

    /// Wait for the resolver's fire-and-forget apply `Task` to reach the state
    /// `condition` describes, sleeping between polls until it holds. A fixed
    /// yield count is racy — 4 yields is enough on an idle machine but not on a
    /// loaded CI runner, where the child `Task`'s `await probe(...)` may not
    /// have resumed yet (this was the #180 flake). We *sleep* rather than
    /// `Task.yield()` because a tight yield loop on `@MainActor` never lets the
    /// clock advance, so it would starve a timer-based continuation; sleeping
    /// hands the actor back long enough for pending work to run. Polling adapts
    /// to scheduling latency; the ~2s ceiling keeps a genuine regression
    /// failing fast instead of hanging the suite.
    private func waitUntil(
        _ condition: () -> Bool,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0 ..< 2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), comment, sourceLocation: sourceLocation)
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
        let probe: @Sendable (ProjectPath, String?) async -> [String: String]? = { spec, _ in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return [:]
        }
        let panes = [remotePane(), remotePane()]
        let t0 = Date()

        resolver.refresh(panes: panes, probe: probe, now: t0)
        resolver.refresh(panes: panes, probe: probe, now: t0.addingTimeInterval(1))
        await waitUntil { calls.value == ["devbox"] }

        resolver.refresh(panes: panes, probe: probe, now: t0.addingTimeInterval(4))
        await waitUntil { calls.value == ["devbox", "devbox"] }
    }

    @Test
    func distinct_hosts_probe_independently_in_one_pass() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        resolver.refresh(panes: [remotePane(host: "alpha"), remotePane(host: "beta")], probe: { spec, _ in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return [:]
        })
        await waitUntil { Set(calls.value) == ["alpha", "beta"] }
    }

    // MARK: - Name application

    @Test
    func applies_probe_names_to_matching_panes() async {
        let pane = remotePane()
        let resolver = RemoteForegroundResolver(minInterval: 0)
        let session = pane.sessionName
        resolver.refresh(panes: [pane], probe: { _, _ in [session: "btop"] })
        await waitUntil { pane.foregroundProcessName == "btop" }
    }

    @Test
    func failed_probe_keeps_last_known_names() async {
        let pane = remotePane()
        pane.applyRemoteForegroundName("btop")
        let resolver = RemoteForegroundResolver(minInterval: 0)
        resolver.refresh(panes: [pane], probe: { _, _ in nil })
        // The failure path changes no name, so there's no state edge to poll —
        // wait for the probe Task to finish, then assert the name held.
        await waitUntil { resolver.isIdle }
        // Silent degradation: the name froze instead of flapping to nil.
        #expect(pane.foregroundProcessName == "btop")
    }
}
