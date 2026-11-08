import Foundation
@testable import Macterm
import Testing

struct ZmxForegroundResolverEntriesTests {
    @Test
    func a_running_session_maps_to_its_shell_and_pty() {
        let entries = ZmxForegroundResolver.entries(from: [
            LocalSession(name: "macterm-proj-abc123", shellPID: 46878, ttyPath: "/dev/ttys012"),
            LocalSession(name: "macterm-proj-def456", shellPID: 47353, ttyPath: nil),
        ])
        #expect(entries == [
            "macterm-proj-abc123": .init(leaderPID: 46878, ttyPath: "/dev/ttys012"),
            "macterm-proj-def456": .init(leaderPID: 47353, ttyPath: nil),
        ])
    }

    @Test
    func an_exited_session_or_one_with_no_shell_is_left_out() {
        let entries = ZmxForegroundResolver.entries(from: [
            LocalSession(name: "macterm-exited", shellPID: 999, ttyPath: "/dev/ttys001", isRunning: false),
            LocalSession(name: "macterm-starting", shellPID: nil),
            LocalSession(name: "macterm-ok", shellPID: 42),
        ])
        #expect(entries == ["macterm-ok": .init(leaderPID: 42, ttyPath: nil)])
    }

    @Test
    func a_server_session_becomes_a_local_session() {
        let session = MactermProtocol.Session(
            id: "macterm-x", state: .running, build: "b", level: 1,
            pid: 10, shellPid: 11, pty: ProtocolBin(Data("/dev/ttys004".utf8)), cols: 80, rows: 24
        )
        #expect(LocalSession(session) == LocalSession(name: "macterm-x", shellPID: 11, ttyPath: "/dev/ttys004"))
        var exited = session
        exited.state = .exited
        #expect(!LocalSession(exited).isRunning)
    }
}

struct ZmxRefreshGateTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t)
    }

    @Test
    func first_ask_refreshes_then_holds_until_ttl() {
        var gate = ZmxRefreshGate()
        #expect(gate.shouldRefresh(now: date(100)) == true)
        // Asking stamped the refresh: quiet until the reconcile TTL.
        #expect(gate.shouldRefresh(now: date(101)) == false)
        #expect(gate.shouldRefresh(now: date(100 + ZmxRefreshGate.reconcileInterval - 1)) == false)
        #expect(gate.shouldRefresh(now: date(100 + ZmxRefreshGate.reconcileInterval)) == true)
    }

    @Test
    func lifecycle_event_forces_a_refresh_before_ttl() {
        var gate = ZmxRefreshGate()
        _ = gate.shouldRefresh(now: date(100))
        gate.noteSessionLifecycle()
        #expect(gate.shouldRefresh(now: date(101)) == true)
        // And the forced refresh restamps the window.
        #expect(gate.shouldRefresh(now: date(102)) == false)
    }

    @Test
    func steady_state_is_at_most_one_refresh_per_interval() {
        var gate = ZmxRefreshGate()
        var refreshes = 0
        // 5 minutes of 250ms polling with no lifecycle events.
        var t = 0.0
        while t < 300 {
            if gate.shouldRefresh(now: date(t)) { refreshes += 1 }
            t += 0.25
        }
        #expect(refreshes == Int(300 / ZmxRefreshGate.reconcileInterval))
    }
}
