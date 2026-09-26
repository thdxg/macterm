import Foundation
@testable import Macterm
import Testing

/// `pane run` captures its text with `.captureForPassthrough`, which takes
/// ArgumentParser's help flags along with it: until the verb answered a leading
/// one itself, `macterm pane run --help` typed `--help` into the focused pane.
/// Run against the bundled CLI with a stand-in control socket that records
/// every request, so a regression shows up here as a request instead of as
/// text typed into a real Macterm.
struct MactermCommandTests {
    @Test
    func pane_run_prints_help_for_a_leading_help_flag_instead_of_typing_it() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        let help = try socket.cli(["help", "pane", "run"])
        #expect(help.status == 0)
        // Flags after the text are typed, so the usage line must list them first.
        let usage = try #require(help.stdout.components(separatedBy: "\n\n").first { $0.hasPrefix("USAGE:") })
        #expect(usage.hasSuffix("<command> ..."), "the flags must come before the text: \(usage)")

        for arguments in [
            ["pane", "run", "--help"],
            ["pane", "run", "-h"],
            ["pane", "run", "--session", "macterm-api-8f327ce4a3f8", "--help"],
            ["pane", "run", "--no-submit", "-h"],
        ] {
            let result = try socket.cli(arguments)
            let invocation = "macterm " + arguments.joined(separator: " ")
            #expect(result.status == 0, "`\(invocation)` exited \(result.status): \(result.stderr)")
            #expect(result.stdout == help.stdout, "`\(invocation)` did not print `macterm help pane run`")
        }
        #expect(socket.requests.isEmpty, "typed into a pane: \(socket.requests.map { $0.args?.run ?? "" })")
    }

    @Test
    func pane_run_types_everything_from_the_first_word_of_its_text() throws {
        let socket = RecordingSocket()
        defer { socket.stop() }
        for arguments in [
            ["pane", "run", "ls", "--help"],
            ["pane", "run", "--no-submit", "--session", "macterm-api-8f327ce4a3f8", "git", "commit", "-h"],
        ] {
            let result = try socket.cli(arguments)
            #expect(result.status == 0, "`macterm \(arguments.joined(separator: " "))`: \(result.stderr)")
        }
        let requests = socket.requests
        #expect(requests.map(\.command) == ["pane.run", "pane.run"])
        #expect(requests.map { $0.args?.run } == ["ls --help", "git commit -h"])
        #expect(requests.map { $0.args?.session } == [nil, "macterm-api-8f327ce4a3f8"])
        #expect(requests.map { $0.args?.submit } == [nil, false])
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
