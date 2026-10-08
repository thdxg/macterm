import Foundation
@testable import Macterm
import Testing

/// `pane run` types the words after `--` verbatim and parses its own flags
/// wherever they appear before it. It used to capture everything from its
/// text's first word on, so `pane run clear --session X` typed
/// `clear --session X` into the CURRENT pane. Run against the bundled CLI
/// with a stand-in control socket that records every request, so a
/// regression shows up here as a request instead of as text typed into a
/// real Macterm.
struct MactermCommandTests {
    private static let session = "macterm-api-8f327ce4a3f8"

    @Test
    func creation_no_focus_is_explicit_and_omission_keeps_the_wire_default() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        for command in [["tab", "new"], ["pane", "split"]] {
            for noFocus in [false, true] {
                let flags = noFocus ? ["--no-focus"] : []
                let result = try socket.cli(command + ["--project", "target", "--run", "echo hello"] + flags)
                #expect(result.status == 0, "\(result.stderr)")
                // `--no-focus` preflights the server's protocol version with a
                // `status` probe before any side effect; the command itself is
                // always the last request.
                let request = try #require(socket.requests.last)
                #expect(request.command == command.joined(separator: "."))
                #expect(request.args?.project == "target")
                #expect(request.args?.run == "echo hello")
                #expect(request.args?.focus == (noFocus ? false : nil))
            }
            let help = try socket.cli(command + ["--help"])
            #expect(help.status == 0)
            #expect(help.stdout.contains("--no-focus"))
        }
        // Two commands × two focus values: the `--no-focus` invocations each
        // preflight with one `status` probe and then send the command; the
        // non-flag invocations send only the command.
        #expect(socket.requests.count(where: { $0.command != "status" }) == 4)
        #expect(socket.requests.count(where: { $0.command == "status" }) == 2)
    }

    @Test(arguments: [["tab", "new"], ["pane", "split"]])
    func no_focus_against_an_older_app_errors_before_creating_anything(command: [String]) throws {
        let socket = RecordingSocket(responseVersion: ControlProtocol.minimumSupportedVersion)
        defer { socket.stop() }
        let result = try socket.cli(command + ["--project", "api", "--no-focus", "--run", "npm test"])
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("upgrade Macterm"), "\(result.stderr)")
        // Only the `status` probe reached the app; the command was never sent.
        #expect(socket.requests.map(\.command) == ["status"])
    }

    @Test(arguments: [["tab", "new"], ["pane", "split"]])
    func default_creation_without_no_focus_succeeds_against_an_older_app(command: [String]) throws {
        let socket = RecordingSocket(responseVersion: ControlProtocol.minimumSupportedVersion)
        defer { socket.stop() }
        let result = try socket.cli(command + ["--project", "target", "--run", "echo hello"])
        #expect(result.status == 0, "\(result.stderr)")
        let request = try #require(socket.requests.last)
        #expect(request.command == command.joined(separator: "."))
        #expect(request.args?.focus == nil)
        // No preflight: an unflagged command keeps v1, so an old app accepts it.
        #expect(socket.requests.map(\.command) == [command.joined(separator: ".")])
    }

    @Test
    func no_focus_refuses_a_failed_version_probe_without_creating_anything() throws {
        let socket = RecordingSocket(probeFails: true)
        defer { socket.stop() }
        let result = try socket.cli(["tab", "new", "--project", "api", "--no-focus"])
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("still starting"))
        #expect(socket.requests.map(\.command) == ["status"])
    }

    @Test
    func no_focus_does_not_fall_through_after_the_probe_verifies_an_app() throws {
        // A newer app answers the probe at the `MACTERM_SOCKET` hint, then dies
        // before the command. An older app listens at the App Support fallback.
        // The command must refuse, not re-run discovery onto the older app.
        // `/tmp` keeps the fallback's socket path under sun_path's ~104 bytes.
        let home = "/tmp/macterm-no-fallback-\(UUID().uuidString.prefix(8))"
        let fallbackPath = "\(home)/Library/Application Support/Macterm/control.sock"
        let fallback = RecordingSocket(
            responseVersion: ControlProtocol.minimumSupportedVersion,
            path: fallbackPath
        )
        defer {
            fallback.stop()
            try? FileManager.default.removeItem(atPath: home)
        }
        let verified = RecordingSocket(
            responseVersion: ControlProtocol.version,
            dropAfterFirstRequest: true
        )
        defer { verified.stop() }

        let result = try verified.cli(
            ["tab", "new", "--project", "api", "--no-focus", "--run", "npm test"],
            environment: ["CFFIXED_USER_HOME": home, "HOME": home]
        )

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("refusing to fall through"), "\(result.stderr)")
        // The probe and the command both went to the verified socket; discovery
        // never re-ran to the (older) fallback.
        #expect(verified.requests.map(\.command) == ["status", "tab.new"])
        #expect(fallback.requests.isEmpty)
    }

    @Test
    func pane_run_prints_help_for_a_help_flag_before_the_terminator() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        let help = try socket.cli(["help", "pane", "run"])
        #expect(help.status == 0)
        let usage = try #require(help.stdout.components(separatedBy: "\n\n").first { $0.hasPrefix("USAGE:") })
        #expect(usage.hasSuffix("[--] <command> ..."), "the usage line must show the terminator: \(usage)")

        for arguments in [
            ["pane", "run", "--help"],
            ["pane", "run", "-h"],
            ["pane", "run", "--session", Self.session, "--help"],
            ["pane", "run", "--no-submit", "-h"],
            ["pane", "run", "ls", "--help"],
        ] {
            let result = try socket.cli(arguments)
            let invocation = "macterm " + arguments.joined(separator: " ")
            #expect(result.status == 0, "`\(invocation)` exited \(result.status): \(result.stderr)")
            #expect(result.stdout == help.stdout, "`\(invocation)` did not print `macterm help pane run`")
        }
        #expect(socket.requests.isEmpty, "typed into a pane: \(socket.requests.map { $0.args?.run ?? "" })")
    }

    @Test
    func pane_run_parses_its_flags_anywhere_and_types_what_follows_the_terminator() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        let cases: [(arguments: [String], run: String, session: String?, submit: Bool?)] = [
            (["pane", "run", "ls"], "ls", nil, nil),
            // The targeting trap: the flag after the text now targets.
            (["pane", "run", "clear", "--session", Self.session], "clear", Self.session, nil),
            (["pane", "run", "--session", Self.session, "--", "ls", "--help"], "ls --help", Self.session, nil),
            (["pane", "run", "--no-submit", "--", "git", "commit", "-h"], "git commit -h", nil, false),
            (["pane", "run", "--", "--session", Self.session], "--session \(Self.session)", nil, nil),
            (["pane", "run", "echo", "--", "-n", "--", "hi"], "echo -n -- hi", nil, nil),
            (["pane", "run", "cat", "-"], "cat -", nil, nil),
            (["pane", "run", "/bin/sh -c 'ls -la'"], "/bin/sh -c 'ls -la'", nil, nil),
        ]
        for (arguments, _, _, _) in cases {
            let result = try socket.cli(arguments)
            #expect(result.status == 0, "`macterm \(arguments.joined(separator: " "))`: \(result.stderr)")
        }
        let requests = socket.requests
        #expect(requests.map(\.command) == cases.map { _ in "pane.run" })
        #expect(requests.map { $0.args?.run } == cases.map(\.run))
        #expect(requests.map { $0.args?.session } == cases.map(\.session))
        #expect(requests.map { $0.args?.submit } == cases.map(\.submit))
    }

    @Test
    func pane_run_refuses_a_dash_word_before_the_terminator_without_typing_it() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        let cases: [(arguments: [String], stray: String, retry: String)] = [
            (["pane", "run", "ls", "-la"], "-la", "macterm pane run -- ls -la"),
            (
                ["pane", "run", "git", "commit", "-m", "two words", "--session", Self.session],
                "-m",
                "macterm pane run --session \(Self.session) -- git commit -m 'two words'"
            ),
            (
                ["pane", "run", "--no-submit", "clear", "--sessio", Self.session],
                "--sessio",
                "macterm pane run --no-submit -- clear --sessio \(Self.session)"
            ),
        ]
        for (arguments, stray, retry) in cases {
            let result = try socket.cli(arguments)
            let invocation = "macterm " + arguments.joined(separator: " ")
            #expect(result.status != 0, "`\(invocation)` was accepted")
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("`\(stray)` is not a `pane run` option"), "\(invocation): \(result.stderr)")
            // The retry it suggests keeps the target, or pasting it would type
            // into the current pane.
            #expect(result.stderr.contains("put the command line after `--`:\n  \(retry)\n"), "\(invocation): \(result.stderr)")
        }
        #expect(socket.requests.isEmpty, "typed into a pane: \(socket.requests.map { $0.args?.run ?? "" })")
    }
}

/// The app's own control server on a throwaway path, recording each request
/// and answering it with a bare ok. `responseVersion` is the protocol version
/// the stand-in app claims to speak, so a test can pose as an older app.
/// `dropAfterFirstRequest` makes the stand-in answer the first request and
/// then close the next one with no response, as if the app vanished.
private final class RecordingSocket {
    // sun_path caps at ~104 bytes and the default tempdir path can be long.
    let path: String
    private let server: ControlSocketServer
    private let received = LockedBox<[ControlRequest]>([])
    init(
        responseVersion: Int = ControlProtocol.version,
        dropAfterFirstRequest: Bool = false,
        probeFails: Bool = false,
        path: String? = nil
    ) {
        self.path = path ?? "/tmp/macterm-test-\(UInt32.random(in: 0 ..< UInt32.max)).sock"
        let version = responseVersion
        let dropLater = dropAfterFirstRequest
        server = ControlSocketServer(socketPath: self.path)
        server.start()
        server.attach { [received, version, dropLater, probeFails] raw in
            let request = try? ControlProtocol.decodeRequest(raw)
            let drop = dropLater && received.value.count >= 1
            if let request { received.mutate { $0.append(request) } }
            if drop { return Data() }
            if probeFails {
                return ControlProtocol.encode(.failure(
                    id: request?.id ?? "",
                    error: ControlError(code: .starting, message: "still starting")
                ))
            }
            return ControlProtocol.encode(ControlResponse(
                v: version,
                id: request?.id ?? "",
                ok: true,
                data: nil,
                error: nil
            ))
        }
    }

    var requests: [ControlRequest] { received.value }

    func stop() {
        server.stop()
    }

    /// The bundled CLI, able to reach this socket as the `MACTERM_SOCKET` hint.
    /// By default discovery's App Support fallback resolves under a home that
    /// doesn't exist, so whatever a regression types can't reach a Macterm the
    /// developer is running; pass `environment` with a real `CFFIXED_USER_HOME`
    /// to place another candidate there (see the no-fallback test).
    func cli(_ arguments: [String], environment: [String: String]? = nil) throws -> BundledCLI.Result {
        var env = environment ?? [:]
        env[ControlProtocol.socketEnvVar] = path
        if env["CFFIXED_USER_HOME"] == nil {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            env["CFFIXED_USER_HOME"] = home
            env["HOME"] = home
        }
        return try BundledCLI.run(arguments, environment: env)
    }
}
