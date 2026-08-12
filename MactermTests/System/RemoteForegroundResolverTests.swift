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
    func parses_session_tab_comm_tab_args_lines() {
        let out = """
        macterm-api-abc123\tbtop\tbtop --utf-force
        macterm-api-def456\t/usr/local/bin/hx\t
        garbage line
        supa-other\tvim\tvim
        macterm-empty\t\t
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-abc123": RemoteForeground(comm: "btop", command: "btop --utf-force"),
            "macterm-api-def456": RemoteForeground(comm: "/usr/local/bin/hx", command: nil),
        ])
    }

    @Test
    func args_keep_embedded_tabs_and_two_field_lines_still_parse() {
        // The args field is the unsplit remainder of the line (a command line
        // may itself contain tabs), and a two-field line (a `ps` that reported
        // no args) degrades to a comm-only foreground.
        let out = """
        macterm-api-abc123\tnode\tnode server.js\t--flag
        macterm-api-legacy\thx
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-abc123": RemoteForeground(comm: "node", command: "node server.js\t--flag"),
            "macterm-api-legacy": RemoteForeground(comm: "hx", command: nil),
        ])
    }

    // MARK: - Cadence gate

    @Test
    func probes_once_per_host_within_the_interval() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let probe: @Sendable (ProjectPath, String?) async -> [String: RemoteForeground]? = { spec, _ in
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
    func boundary_request_bypasses_the_interval_and_is_consumed() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let pane = remotePane()
        // The probe names the session: this test is about the boundary
        // request's throttle-bypass in steady state, not the registration
        // race (a listing that misses the session re-arms the request and
        // would defeat the throttled expectations below).
        let session = pane.sessionName
        let probe: @Sendable (ProjectPath, String?) async -> [String: RemoteForeground]? = { spec, _ in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return [session: RemoteForeground(comm: "bash", command: nil)]
        }
        let t0 = Date()
        resolver.refresh(panes: [pane], probe: probe, now: t0)
        await waitUntil { calls.value == ["devbox"] }

        // Within the interval with no boundary: throttled.
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(1))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == ["devbox"])

        // A command boundary (#210's remote mirror) bypasses the interval…
        pane.noteRemoteCommandBoundary()
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(2))
        await waitUntil { calls.value == ["devbox", "devbox"] }

        // …and the fired probe consumes the request, restoring the throttle.
        #expect(!pane.remoteProbePending)
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(2.5))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == ["devbox", "devbox"])
    }

    @Test
    func registration_race_rearms_until_the_session_appears() async {
        // A fresh session takes seconds to register on the host, so early
        // probes succeed but list nothing for it. Each miss must re-arm the
        // pane's request so the retry survives its project leaving the
        // frontmost slot; the probe that finally names it ends the loop.
        let calls = LockedBox<Int>(0)
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let pane = remotePane()
        let session = pane.sessionName
        let probe: @Sendable (ProjectPath, String?) async -> [String: RemoteForeground]? = { _, _ in
            calls.mutate { $0 += 1 }
            // Registered from the third probe on.
            return calls.value >= 3 ? [session: RemoteForeground(comm: "bash", command: nil)] : [:]
        }
        let t0 = Date()
        // Init primes the first request; each miss re-arms, bypassing the
        // interval on every subsequent tick.
        resolver.refresh(panes: [pane], probe: probe, now: t0)
        await waitUntil { resolver.isIdle }
        #expect(pane.remoteProbePending)
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(1))
        await waitUntil { resolver.isIdle }
        #expect(pane.remoteProbePending)
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(2))
        await waitUntil { resolver.isIdle }

        // Named — the request is answered, not re-armed.
        #expect(pane.foregroundProcessName == "bash")
        #expect(!pane.remoteProbePending)
        #expect(calls.value == 3)
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
    func applies_probe_names_and_commands_to_matching_panes() async {
        let pane = remotePane()
        let resolver = RemoteForegroundResolver(minInterval: 0)
        let session = pane.sessionName
        resolver.refresh(panes: [pane], probe: { _, _ in
            [session: RemoteForeground(comm: "btop", command: "btop --utf-force")]
        })
        await waitUntil { pane.foregroundProcessName == "btop" }
        // The full command line lands too — Save Layout's `run:` source.
        #expect(pane.remoteForegroundCommand == "btop --utf-force")
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
