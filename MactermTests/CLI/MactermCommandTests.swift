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
/// and answering it with a bare ok.
private final class RecordingSocket {
    // sun_path caps at ~104 bytes and the default tempdir path can be long.
    private let path = "/tmp/macterm-test-\(UInt32.random(in: 0 ..< UInt32.max)).sock"
    private let server: ControlSocketServer
    private let received = LockedBox<[ControlRequest]>([])

    init() {
        server = ControlSocketServer(socketPath: path)
        server.start()
        server.attach { [received] raw in
            let request = try? ControlProtocol.decodeRequest(raw)
            if let request { received.mutate { $0.append(request) } }
            return ControlProtocol.encode(.success(id: request?.id ?? ""))
        }
    }

    var requests: [ControlRequest] { received.value }

    func stop() {
        server.stop()
    }

    /// The bundled CLI, able to reach this socket and nothing else: it is the
    /// `MACTERM_SOCKET` hint, and discovery's App Support fallback resolves
    /// under a home that doesn't exist. `CFFIXED_USER_HOME` is what moves it —
    /// `NSHomeDirectory` ignores `HOME` — so whatever a regression types can't
    /// reach a Macterm the developer is running.
    func cli(_ arguments: [String]) throws -> BundledCLI.Result {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        return try BundledCLI.run(arguments, environment: [
            ControlProtocol.socketEnvVar: path,
            "CFFIXED_USER_HOME": home,
            "HOME": home,
        ])
    }
}
