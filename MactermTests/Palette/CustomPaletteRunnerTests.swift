import Foundation
@testable import Macterm
import Testing

/// How a palette's commands run (`CustomPaletteScript`): sh, or the
/// interpreter a `#!` names, started from the login shell through one fixed
/// line; and the probe `requires:` uses to name a missing program.
struct CustomPaletteRunnerTests {
    /// The trampoline run by `loginShell` as the runner would run it, minus
    /// `-l` (a test's rc files are nobody's business).
    private static func run(
        _ command: String,
        loginShell: String,
        environment: [String: String] = [:]
    ) throws -> (stdout: String, status: Int32) {
        let invocation = CustomPaletteScript.invocation(of: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-c", invocation.line]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
            .merging(environment) { _, new in new }
            .merging(invocation.environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (stdout, process.terminationStatus)
    }

    @Test
    func the_login_shell_is_handed_one_fixed_line_and_the_command_rides_in_the_environment() {
        let invocation = CustomPaletteScript.invocation(of: #"kubectl get pods -n "$NAMESPACE""#)
        #expect(invocation.line == CustomPaletteScript.trampoline)
        #expect(invocation.environment == [CustomPaletteScript.commandVariable: #"kubectl get pods -n "$NAMESPACE""#])
        // The only syntax the login shell sees is one single-quoted string,
        // which nu, fish, zsh and bash all read literally — so it may hold
        // neither of the two characters fish's single quotes interpret.
        #expect(CustomPaletteScript.trampoline.hasPrefix("/bin/sh -c '"))
        #expect(CustomPaletteScript.trampoline.count(where: { $0 == "'" }) == 2)
        #expect(!CustomPaletteScript.trampoline.contains("\\"))
    }

    /// Run for real by the shells every Mac has, standing in for the login
    /// shell: the command arrives intact, quotes and all, and runs in sh.
    @Test(arguments: ["/bin/zsh", "/bin/bash", "/bin/sh"])
    func a_command_without_a_shebang_runs_in_sh(loginShell: String) throws {
        let result = try Self.run(
            #"if [ -n "$NS" ]; then set -- -n "$NS"; else set -- -A; fi; printf "%s|" "$@""#,
            loginShell: loginShell,
            environment: ["NS": #"it's "prod" $HOME"#]
        )
        #expect(result.status == 0)
        #expect(result.stdout == #"-n|it's "prod" $HOME|"#)
    }

    @Test
    func a_command_stops_at_its_first_failure_and_an_indented_shebang_still_counts() throws {
        let stopped = try Self.run("printf one; false; printf two", loginShell: "/bin/zsh")
        #expect(stopped.status == 1, "errexit, as mise runs a task")
        #expect(stopped.stdout == "one")
        #expect(try Self.run("false || printf handled", loginShell: "/bin/zsh").stdout == "handled")

        #expect(CustomPaletteScript.script("\n  #!/bin/zsh\nprint hi") == "#!/bin/zsh\nprint hi")
        #expect(try Self.run("\n  #!/bin/zsh\nprint -r -- $ZSH_NAME", loginShell: "/bin/bash").stdout == "zsh\n")
    }

    @Test
    func a_command_with_a_shebang_runs_as_a_script_with_that_interpreter_and_leaves_nothing_behind() throws {
        let marker = UUID().uuidString
        let result = try Self.run(
            """
            #!/bin/zsh
            print -r -- "zsh $ZSH_VERSION[1] \(marker) ${MACTERM_PALETTE_COMMAND:-unset}"
            exit 4
            """,
            loginShell: "/bin/bash"
        )
        #expect(result.status == 4, "the script's status is the command's")
        #expect(result.stdout == "zsh 5 \(marker) unset\n", "zsh ran it, and the command isn't passed on")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { name in
            guard name.hasPrefix("macterm-palette.") else { return false }
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
            return (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) == true
        }
        #expect(leftovers.isEmpty)
    }

    @Test
    func a_failing_command_keeps_its_status() throws {
        #expect(try Self.run("exit 3", loginShell: "/bin/zsh").status == 3)
        #expect(try Self.run("macterm-no-such-program", loginShell: "/bin/zsh").status == 127)
    }

    /// Whether a process whose command line contains `marker` is running.
    private static func running(_ marker: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `command` through the real runner the way a listing runs it: the
    /// login shell handed the trampoline, the command in the environment.
    private static func list(_ command: String, timeout: Duration) async throws -> CustomPaletteCommandResult {
        let invocation = CustomPaletteScript.invocation(of: command)
        return try await CustomPaletteRunner.runner(timeout: timeout)(invocation.line, invocation.environment, nil)
    }

    /// A unique `sleep` duration, so `pgrep` finds this test's process only.
    private static func marker() -> String {
        "3\(Int.random(in: 100 ... 999)).\(Int.random(in: 1000 ... 9999))"
    }

    /// A timeout ends the whole command — every stage of a pipeline, not
    /// just the login shell — and returns at once rather than when the
    /// pipeline's last process finally lets go of the output pipe.
    @Test
    func a_timeout_ends_the_command_and_everything_it_started() async throws {
        let marker = Self.marker()
        let started = ContinuousClock.now
        await #expect(throws: CustomPaletteRunner.TimedOut.self) {
            try await Self.list("sleep \(marker) | cat", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!Self.running("sleep \(marker)"), "nothing it started is left running")
    }

    /// A listing ends when its command does: what it left running in the
    /// background is ended rather than holding the output open.
    @Test
    func a_listing_ends_when_its_command_does() async throws {
        let marker = Self.marker()
        let started = ContinuousClock.now
        let result = try await Self.list("(sleep \(marker) &); echo listed", timeout: .seconds(20))
        #expect(result.stdout.contains("listed"))
        #expect(ContinuousClock.now - started < .seconds(10))
        try await Task.sleep(for: .milliseconds(500))
        #expect(!Self.running("sleep \(marker)"))
    }

    /// Closing the palette cancels the listing's task, and that ends the
    /// command too.
    @Test
    func a_cancelled_listing_ends_its_command() async throws {
        let marker = Self.marker()
        let listing = Task { try await Self.list("sleep \(marker)", timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(Self.running("sleep \(marker)"))
        listing.cancel()
        _ = try? await listing.value
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!Self.running("sleep \(marker)"))
    }

    /// A command is never `sh`'s options, however it starts.
    @Test
    func a_command_starting_with_a_dash_is_a_command() throws {
        let result = try Self.run("-x", loginShell: "/bin/zsh")
        #expect(result.status == 127)
        #expect(try Self.run("#!/bin/sh", loginShell: "/bin/zsh").status == 0, "a one-line script with no newline runs")
    }

    @Test
    func a_program_name_is_one_word_with_nothing_a_shell_expands() {
        for name in ["kubectl", "jq", "docker-compose", "python3.12", "g++", "/usr/local/bin/helm"] {
            #expect(CustomPaletteRequirements.isProgramName(name), "\(name)")
        }
        for name in ["", "kubectl jq", "-v", "k*", "a;b", "$(x)", "ünï"] {
            #expect(!CustomPaletteRequirements.isProgramName(name), "\(name)")
        }
    }

    @Test
    func the_probe_reports_the_missing_programs_in_the_files_order() async {
        final class Calls: @unchecked Sendable {
            var seen: [(command: String, environment: [String: String])] = []
        }
        let calls = Calls()
        let missing = await CustomPaletteRequirements.missing(
            ["kubectl", "jq", "helm"],
            environment: ["PATH": "/somewhere"],
            currentDirectory: "/tmp"
        ) { command, environment, _ in
            calls.seen.append((command, environment))
            return CustomPaletteCommandResult(stdout: "helm\nkubectl\n", stderr: "", status: 0)
        }
        #expect(missing == ["kubectl", "helm"])
        #expect(calls.seen.count == 1)
        #expect(calls.seen[0].command == CustomPaletteScript.trampoline)
        #expect(calls.seen[0].environment[CustomPaletteScript.commandVariable] == CustomPaletteRequirements.probe)
        #expect(calls.seen[0].environment[CustomPaletteRequirements.variable] == "kubectl jq helm")
        #expect(calls.seen[0].environment["PATH"] == "/somewhere")

        let failedProbe = await CustomPaletteRequirements.missing(["kubectl"], environment: [:], currentDirectory: nil) { _, _, _ in
            CustomPaletteCommandResult(stdout: "kubectl\n", stderr: "", status: 1)
        }
        #expect(failedProbe.isEmpty, "a probe that fails says nothing")
        let nothingRequired = await CustomPaletteRequirements.missing([], environment: [:], currentDirectory: nil) { _, _, _ in
            Issue.record("nothing to probe for")
            return CustomPaletteCommandResult(stdout: "", stderr: "", status: 0)
        }
        #expect(nothingRequired.isEmpty)
    }

    @Test
    func the_probe_finds_what_is_on_path_for_real() async {
        let missing = await CustomPaletteRequirements.missing(
            ["sh", "macterm-no-such-program", "ls"],
            environment: [:],
            currentDirectory: nil
        ) { command, environment, _ in
            #expect(command == CustomPaletteScript.trampoline)
            let script = try #require(environment[CustomPaletteScript.commandVariable])
            let result = try Self.run(script, loginShell: "/bin/zsh", environment: environment)
            return CustomPaletteCommandResult(stdout: result.stdout, stderr: "", status: result.status)
        }
        #expect(missing == ["macterm-no-such-program"])
    }

    @Test
    func the_message_names_every_missing_program() {
        #expect(CustomPaletteRequirements.message(missing: ["kubectl"])
            == "This palette needs kubectl, which isn't on your PATH.")
        #expect(CustomPaletteRequirements.message(missing: ["kubectl", "jq"])
            == "This palette needs kubectl and jq, which aren't on your PATH.")
        #expect(CustomPaletteRequirements.message(missing: ["kubectl", "jq", "helm"])
            == "This palette needs kubectl, jq and helm, which aren't on your PATH.")
    }
}
