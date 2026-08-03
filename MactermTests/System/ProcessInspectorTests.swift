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

    /// Every nushell pane runs the exact argv below — ghostty's command-wrapper
    /// injects `--execute 'use ghostty *'` to load shell integration. Unlike
    /// `-c`, nushell's `--execute` runs its code and THEN enters the
    /// interactive REPL, so the invocation is an idle shell. Reading it as
    /// foreground work costs the execution tracker its return-to-prompt
    /// completion edge, which stranded the tab spinner for the whole
    /// quiet-settle window after fast commands.
    @Test
    func shellIntegrationExecuteInvocation_isIdleShell() throws {
        // Resolved from the host's own login shell, not a hardcoded `nu` path:
        // shell names come from `/etc/shells`, so a literal nushell argv would
        // not even parse as a shell on a runner without nushell installed.
        let loginShellPtr = try #require(getpwuid(getuid())?.pointee.pw_shell)
        let shell = String(cString: loginShellPtr)
        let loginName = (shell as NSString).lastPathComponent

        #expect(ProcessInspector.isIdleShellInvocation([shell, "--execute", "use ghostty *"]))
        #expect(ProcessInspector.isIdleShellInvocation(["-\(loginName)", "--execute", "use ghostty *"]))
        // The value is skipped, not scanned — a real command after it still counts.
        #expect(!ProcessInspector.isIdleShellInvocation([shell, "--execute", "use ghostty *", "-c", "sleep 10"]))
        #expect(!ProcessInspector.isIdleShellInvocation([shell, "--execute", "use ghostty *", "script.sh"]))
    }

    @Test
    func terminalInputIsRaw_reads_tty_input_mode() throws {
        // openpty's two fds: the primary (controlling) end and the secondary
        // (subordinate) end — the modern names for the pty pair.
        var primary: Int32 = -1
        var secondary: Int32 = -1
        #expect(openpty(&primary, &secondary, nil, nil, nil) == 0)
        defer {
            if primary >= 0 { close(primary) }
            if secondary >= 0 { close(secondary) }
        }
        let path = try String(cString: #require(ttyname(secondary)))

        #expect(ProcessInspector.terminalInputIsRaw(ttyPath: path) == false)

        var attrs = termios()
        #expect(tcgetattr(secondary, &attrs) == 0)
        attrs.c_lflag &= ~tcflag_t(ICANON)
        attrs.c_lflag &= ~tcflag_t(ECHO)
        #expect(tcsetattr(secondary, TCSANOW, &attrs) == 0)

        #expect(ProcessInspector.terminalInputIsRaw(ttyPath: path) == true)
    }

    // MARK: - Invoked name (agent-icon fallback)

    @Test
    func invokedName_uses_argv0_basename() {
        #expect(ProcessInspector.invokedName(argv: ["/usr/local/bin/claude"]) == "claude")
        #expect(ProcessInspector.invokedName(argv: ["claude", "--continue"]) == "claude")
        #expect(ProcessInspector.invokedName(argv: ["-zsh"]) == "zsh")
        #expect(ProcessInspector.invokedName(argv: []) == nil)
    }

    @Test
    func invokedName_resolves_interpreter_scripts() {
        // npm shims: `node <bin script>` — the script names the CLI.
        #expect(ProcessInspector.invokedName(argv: ["node", "/usr/local/lib/node_modules/.bin/pi"]) == "pi")
        #expect(ProcessInspector.invokedName(argv: ["/opt/homebrew/bin/node", "/x/gemini.js"]) == "gemini")
        // A flag (not a script) after the interpreter falls back to the
        // interpreter name; so does a bare interpreter REPL.
        #expect(ProcessInspector.invokedName(argv: ["node", "--version"]) == "node")
        #expect(ProcessInspector.invokedName(argv: ["node"]) == "node")
    }

    @Test
    func isInterpreterName_only_matches_interpreters() {
        #expect(ProcessInspector.isInterpreterName("node"))
        #expect(ProcessInspector.isInterpreterName("Python3"))
        #expect(!ProcessInspector.isInterpreterName("claude"))
        #expect(!ProcessInspector.isInterpreterName("zsh"))
    }
}
