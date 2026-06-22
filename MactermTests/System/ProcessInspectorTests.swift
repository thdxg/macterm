import Darwin
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
    private func withProcess(_ launchPath: String, _ args: [String], cwd: String? = nil, _ body: (pid_t) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
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

    @Test
    func workingDirectory_reads_the_process_cwd() throws {
        // The kernel reports the fully symlink-resolved cwd (e.g. /var/folders
        // → /private/var/folders on macOS), so compare against realpath of the
        // launch dir rather than the raw path.
        let launchDir = FileManager.default.temporaryDirectory.path
        let resolved = try #require(launchDir.withCString { realpath($0, nil) })
        defer { free(resolved) }
        let expected = String(cString: resolved)
        withProcess("/bin/sleep", ["91"], cwd: launchDir) { pid in
            #expect(ProcessInspector.workingDirectory(pid: pid) == expected)
        }
    }

    @Test
    func workingDirectory_returns_nil_for_nonexistent_pid() {
        #expect(ProcessInspector.workingDirectory(pid: 999_999) == nil)
    }

    @Test
    func shellDetection_uses_system_shells() throws {
        let loginShellPtr = try #require(getpwuid(getuid())?.pointee.pw_shell)
        let loginShell = String(cString: loginShellPtr)
        let loginShellName = (loginShell as NSString).lastPathComponent

        #expect(ProcessInspector.isShellProcessName(loginShell))
        #expect(ProcessInspector.isShellProcessName("-\(loginShellName)"))
        #expect(!ProcessInspector.isShellProcessName("macterm-definitely-not-a-shell"))
    }

    @Test
    func shellScriptInvocation_isNotIdleShell() {
        #expect(ProcessInspector.isIdleShellInvocation(["/bin/bash"]))
        #expect(ProcessInspector.isIdleShellInvocation(["/bin/bash", "-l"]))
        // This is only an argv shape; the script path is not opened.
        #expect(!ProcessInspector.isIdleShellInvocation(["/bin/bash", "/path/to/script.sh"]))
        #expect(!ProcessInspector.isIdleShellInvocation(["/bin/bash", "-c", "sleep 10"]))
        #expect(!ProcessInspector.isIdleShellInvocation(["/bin/bash", "-lc", "sleep 10"]))
    }

    @Test
    func terminalInputIsRaw_reads_tty_input_mode() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
        }
        let path = try String(cString: #require(ttyname(slave)))

        #expect(ProcessInspector.terminalInputIsRaw(ttyPath: path) == false)

        var attrs = termios()
        #expect(tcgetattr(slave, &attrs) == 0)
        attrs.c_lflag &= ~tcflag_t(ICANON)
        attrs.c_lflag &= ~tcflag_t(ECHO)
        #expect(tcsetattr(slave, TCSANOW, &attrs) == 0)

        #expect(ProcessInspector.terminalInputIsRaw(ttyPath: path) == true)
    }
}
