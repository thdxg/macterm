import Foundation
@testable import Macterm
import Testing

/// Covers `ProcessInspector.argv` — the syscall-backed parsing — against real
/// spawned subprocesses (same uid as the test host, so readable). The full
/// `runningCommand(forPane:)` path additionally needs a live libghostty surface
/// (for the foreground pid), which isn't available in unit tests; it's
/// exercised by the manual end-to-end run instead.
@MainActor
struct ProcessInspectorTests {
    /// Launch a process directly (no shell, so argv is deterministic from the
    /// start), run `body` against its pid, then terminate it. Polls briefly for
    /// the pid to become readable.
    private func withProcess(_ launchPath: String, _ args: [String], _ body: (pid_t) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        do {
            try proc.run()
        } catch {
            Issue.record("failed to launch test process: \(error)")
            return
        }
        defer {
            proc.terminate()
            proc.waitUntilExit()
        }

        let pid = proc.processIdentifier
        for _ in 0 ..< 50 where ProcessInspector.argv(pid: pid) == nil {
            usleep(10000)
        }
        body(pid)
    }

    @Test
    func argv_reads_the_argument_vector() {
        // Launch /bin/sleep directly → argv is [/bin/sleep, <n>], no exec race.
        withProcess("/bin/sleep", ["91"]) { pid in
            #expect(ProcessInspector.argv(pid: pid) == ["/bin/sleep", "91"])
        }
    }

    @Test
    func argv_returns_nil_for_nonexistent_pid() {
        #expect(ProcessInspector.argv(pid: 999_999) == nil)
    }
}
