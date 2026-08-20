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
    func parses_session_tab_comm_tab_idleflag_tab_args_lines() {
        // Garbage and non-macterm sessions drop; an empty args field is a
        // nil command.
        let out = """
        macterm-api-abc123\tbtop\t0\tbtop --utf-force
        macterm-api-def456\t/usr/local/bin/hx\t0\t
        garbage line
        supa-other\tvim\t0\tvim
        macterm-empty\t\t\t
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-abc123": RemoteForeground(comm: "btop", isIdle: false, command: "btop --utf-force"),
            "macterm-api-def456": RemoteForeground(comm: "/usr/local/bin/hx", isIdle: false, command: nil),
        ])
    }

    @Test
    func parses_the_host_idle_flag() {
        // `1` = the session leader's group owns the tty (shell at prompt),
        // `0` = another group holds the foreground, empty/garbage = the pgid
        // read failed on the host — unknown, never invented.
        let out = """
        macterm-api-idle\t-bash\t1\t-bash
        macterm-api-busy\tbtop\t0\tbtop
        macterm-api-unknown\thx\t\thx
        macterm-api-garbage\tvim\tmaybe\tvim
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-idle": RemoteForeground(comm: "-bash", isIdle: true, command: "-bash"),
            "macterm-api-busy": RemoteForeground(comm: "btop", isIdle: false, command: "btop"),
            "macterm-api-unknown": RemoteForeground(comm: "hx", isIdle: nil, command: "hx"),
            "macterm-api-garbage": RemoteForeground(comm: "vim", isIdle: nil, command: "vim"),
        ])
    }

    @Test
    func args_keep_embedded_tabs_and_short_lines_still_parse() {
        // The args field is the unsplit remainder of the line (a command line
        // may itself contain tabs) — which is why the fixed-width idle flag
        // sits BEFORE it. Two- and three-field lines (degraded probes)
        // degrade to comm-only / command-less foregrounds.
        let out = """
        macterm-api-abc123\tnode\t0\tnode server.js\t--flag
        macterm-api-legacy\thx
        macterm-api-flagonly\thx\t0
        """
        let map = RemoteForegroundResolver.parseProbeOutput(out)
        #expect(map == [
            "macterm-api-abc123": RemoteForeground(comm: "node", isIdle: false, command: "node server.js\t--flag"),
            "macterm-api-legacy": RemoteForeground(comm: "hx", isIdle: nil, command: nil),
            "macterm-api-flagonly": RemoteForeground(comm: "hx", isIdle: false, command: nil),
        ])
    }

    // MARK: - Cadence gate

    @Test
    func probes_once_per_host_within_the_interval() async {
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { spec, _ in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return .success([:])
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
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { spec, _ in
            if case let .remote(_, host, _) = spec { calls.mutate { $0.append(host) } }
            return .success([session: RemoteForeground(comm: "bash", isIdle: true, command: nil)])
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
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { _, _ in
            calls.mutate { $0 += 1 }
            // Registered from the third probe on.
            return .success(calls.value >= 3 ? [session: RemoteForeground(comm: "bash", isIdle: true, command: nil)] : [:])
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
            return .success([:])
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
            .success([session: RemoteForeground(comm: "btop", isIdle: false, command: "btop --utf-force")])
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
        resolver.refresh(panes: [pane], probe: { _, _ in .unreachable })
        // The failure path changes no name, so there's no state edge to poll —
        // wait for the probe Task to finish, then assert the name held.
        await waitUntil { resolver.isIdle }
        // Silent degradation: the name froze instead of flapping to nil.
        #expect(pane.foregroundProcessName == "btop")
    }

    // MARK: - Auth-refusal gate (#272)

    @Test
    func classifies_ssh_failure_stderr() {
        // "Permission denied" is what a cancelled Touch ID dialog produces
        // once BatchMode blocks the interactive fallbacks; anything else
        // (timeouts, DNS, dropped links) must stay transient.
        #expect(RemoteProbeOutcome.classifyFailure(
            stderr: "seth@devbox: Permission denied (publickey,password)."
        ) == .authRefused)
        #expect(RemoteProbeOutcome.classifyFailure(
            stderr: "Received disconnect: Too many authentication failures"
        ) == .authRefused)
        #expect(RemoteProbeOutcome.classifyFailure(
            stderr: "ssh: connect to host devbox port 22: Operation timed out"
        ) == .unreachable)
        #expect(RemoteProbeOutcome.classifyFailure(
            stderr: "ssh: Could not resolve hostname devbox"
        ) == .unreachable)
        #expect(RemoteProbeOutcome.classifyFailure(stderr: "") == .unreachable)
    }

    @Test
    func auth_refusal_suspends_the_host_and_boundary_requests_do_not_bypass() async {
        // A refused probe must be the LAST probe of the run for that host:
        // with a biometric-gated key every retry is a system dialog, so
        // neither the scheduled interval nor a boundary request may re-fire.
        let calls = LockedBox<Int>(0)
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let pane = remotePane()
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { _, _ in
            calls.mutate { $0 += 1 }
            return .authRefused
        }
        let t0 = Date()
        resolver.refresh(panes: [pane], probe: probe, now: t0)
        await waitUntil { calls.value == 1 && resolver.isIdle }

        // Past the interval: still suspended.
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(10))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == 1)

        // A command boundary bypasses the throttle but never the auth gate.
        pane.noteRemoteCommandBoundary()
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(20))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == 1)
    }

    @Test
    func unreachable_probe_keeps_the_scheduled_retry() async {
        // The transient failure must NOT inherit the auth gate: a flaky link
        // recovers on its own, so the next tick past the interval retries.
        let calls = LockedBox<Int>(0)
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let pane = remotePane()
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { _, _ in
            calls.mutate { $0 += 1 }
            return .unreachable
        }
        let t0 = Date()
        resolver.refresh(panes: [pane], probe: probe, now: t0)
        await waitUntil { calls.value == 1 && resolver.isIdle }
        resolver.refresh(panes: [pane], probe: probe, now: t0.addingTimeInterval(4))
        await waitUntil { calls.value == 2 }
    }

    @Test
    func a_new_pane_on_the_host_retests_a_refused_gate_once() async {
        // A never-seen pane means a fresh interactive connection to the host
        // — the one moment a retest is worth a possible prompt (a user who
        // configured ControlMaster since gets full naming back). Refused
        // again, the gate re-arms until the next new pane.
        let calls = LockedBox<Int>(0)
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let first = remotePane()
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { _, _ in
            calls.mutate { $0 += 1 }
            return .authRefused
        }
        let t0 = Date()
        resolver.refresh(panes: [first], probe: probe, now: t0)
        await waitUntil { calls.value == 1 && resolver.isIdle }
        resolver.refresh(panes: [first], probe: probe, now: t0.addingTimeInterval(10))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == 1)

        // A new pane (primed request from init) clears the gate for one probe…
        let second = remotePane()
        resolver.refresh(panes: [first, second], probe: probe, now: t0.addingTimeInterval(20))
        await waitUntil { calls.value == 2 && resolver.isIdle }

        // …and the repeated refusal re-gates: the same panes stay silent.
        resolver.refresh(panes: [first, second], probe: probe, now: t0.addingTimeInterval(30))
        await waitUntil { resolver.isIdle }
        #expect(calls.value == 2)
    }

    @Test
    func the_auth_gate_is_per_host() async {
        // alpha refusing must not cost beta its probes.
        let calls = LockedBox<[String]>([])
        let resolver = RemoteForegroundResolver(minInterval: 3)
        let alpha = remotePane(host: "alpha")
        let beta = remotePane(host: "beta")
        let probe: @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome = { spec, _ in
            guard case let .remote(_, host, _) = spec else { return .unreachable }
            calls.mutate { $0.append(host) }
            return host == "alpha" ? .authRefused : .success([:])
        }
        let t0 = Date()
        resolver.refresh(panes: [alpha, beta], probe: probe, now: t0)
        await waitUntil { Set(calls.value) == ["alpha", "beta"] && resolver.isIdle }

        resolver.refresh(panes: [alpha, beta], probe: probe, now: t0.addingTimeInterval(10))
        await waitUntil { calls.value.count(where: { $0 == "beta" }) == 2 }
        #expect(calls.value.count(where: { $0 == "alpha" }) == 1)
    }
}
