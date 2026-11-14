import Foundation
@testable import Macterm
import Testing

/// The v1 CLI contract as files (`Golden/`), checked against the bundled
/// `macterm`. The Zig port of the CLI (design 011) must pass the same files.
///
/// - `Golden/tree.json`: the command tree, as `--experimental-dump-help` prints it.
/// - `Golden/help/<verb path>.txt`: the `--help` text of every command in the tree.
/// - `Golden/cases.json`: for each argument line, the requests the CLI sends to a
///   stand-in app that answers with a canned response, and what the CLI prints.
///
/// The test host is a Debug build, so the tree and the help include the debug
/// verbs (their abstract starts with `[debug]`). The port reads them as
/// optional.
///
/// To change a golden file on purpose, delete it and run this suite: the test
/// writes the file again and fails, so that the diff gets reviewed.
struct CLIContractTests {
    private static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")

    // MARK: - Tree and help

    /// ArgumentParser wraps help at `COLUMNS`, so the runs that print help pin it.
    private static let helpEnvironment = ["COLUMNS": "80", "HOME": "/var/empty"]

    @Test
    func the_command_tree_is_the_golden_file() throws {
        let tree = try Self.tree()
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
        try Self.compare(String(decoding: data, as: UTF8.self) + "\n", to: "tree.json")
    }

    @Test
    func every_command_prints_its_golden_help() throws {
        var expected: Set<String> = []
        // `palette exec` is the raw runner of a palette `run:` action: it reads
        // its argv itself and has no help. Its case is in `cases`.
        for path in try Self.commandPaths(in: Self.tree()) where path != ["palette", "exec"] {
            let result = try BundledCLI.run(path + ["--help"], environment: Self.helpEnvironment)
            #expect(result.status == 0, "macterm \(path.joined(separator: " ")) --help: \(result.stderr)")
            #expect(result.stderr.isEmpty)
            let name = (path.isEmpty ? ["macterm"] : path).joined(separator: "-") + ".txt"
            expected.insert(name)
            try Self.compare(result.stdout, to: "help/\(name)")
        }
        let present = try FileManager.default.contentsOfDirectory(atPath: Self.goldenDirectory.appendingPathComponent("help").path)
        #expect(Set(present.filter { $0.hasSuffix(".txt") }) == expected, "a help file has no command in the tree")
    }

    // MARK: - Requests and output

    /// One line of arguments, with the response that the stand-in app gives to
    /// the command that it sends (the key is the wire command).
    private struct Case {
        let arguments: [String]
        var responses: [String: String] = [:]
        /// The protocol version that the stand-in app speaks.
        var statusVersion = ControlProtocol.version
    }

    private static let cases: [Case] = [
        Case(
            arguments: ["status"],
            responses: ["status": ok(#""status":{"version":"1.34.0","pid":4242,"activeProject":"api","activeProjectID":"P1"}"#)]
        ),
        Case(
            arguments: ["status", "--json"],
            responses: ["status": ok(#""status":{"version":"1.34.0","pid":4242,"activeProject":"api","activeProjectID":"P1"}"#)]
        ),
        Case(arguments: ["status"], responses: ["status": ok(#""status":{"version":"1.34.0","pid":4242}"#)]),
        // Projects
        Case(arguments: ["project", "list"], responses: ["project.list": ok(projects)]),
        Case(arguments: ["project", "list", "--json"], responses: ["project.list": ok(projects)]),
        Case(arguments: ["project", "create", "/tmp/api", "--name", "api", "--select"], responses: ["project.create": ok(projects)]),
        Case(arguments: ["project", "create", "/tmp/api"], responses: ["project.create": ok(projects)]),
        Case(arguments: ["project", "select", "api"], responses: ["project.select": ok(projects)]),
        Case(arguments: ["project", "select", "api", "--window", "2"], responses: ["project.select": ok(projects)]),
        Case(arguments: ["project", "rename", "api", "backend"], responses: ["project.rename": ok(projects)]),
        Case(arguments: ["project", "remove", "api", "--force"], responses: ["project.remove": ok("")]),
        Case(
            arguments: ["project", "remove", "api"],
            responses: ["project.remove": failure("busy", "a pane in api runs a program", "pass --force")]
        ),
        // Tabs
        Case(arguments: ["tab", "list"], responses: ["tab.list": ok(tabs)]),
        Case(arguments: ["tab", "list", "--project", "api", "--json"], responses: ["tab.list": ok(tabs)]),
        Case(arguments: ["tab", "new", "--project", "api", "--run", "npm test"], responses: ["tab.new": ok(tabs)]),
        Case(arguments: ["tab", "new", "--no-focus"], responses: ["tab.new": ok(tabs)]),
        Case(arguments: ["tab", "select", "2"], responses: ["tab.select": ok(tabs)]),
        Case(arguments: ["tab", "rename", "2", "build"], responses: ["tab.rename": ok(tabs)]),
        Case(arguments: ["tab", "rename", "2", "--reset"], responses: ["tab.rename": ok(tabs)]),
        Case(arguments: ["tab", "move", "2", "1"], responses: ["tab.move": ok(tabs)]),
        Case(arguments: ["tab", "close", "2", "--force"], responses: ["tab.close": ok("")]),
        Case(arguments: ["tab", "close", "9"], responses: ["tab.close": failure("not_found", "no tab 9", nil)]),
        // Panes
        Case(arguments: ["pane", "list"], responses: ["pane.list": ok(panes)]),
        Case(arguments: ["pane", "list", "--json"], responses: ["pane.list": ok(panes)]),
        Case(arguments: ["pane", "inspect"], responses: ["pane.inspect": ok(inspect)]),
        Case(arguments: ["pane", "inspect", "--json"], responses: ["pane.inspect": ok(inspect)]),
        Case(arguments: ["pane", "dump"], responses: ["pane.dump": ok(dump)]),
        Case(arguments: ["pane", "dump", "--scrollback", "--session", "macterm-api-8f327ce4a3f8"], responses: ["pane.dump": ok(dump)]),
        Case(arguments: ["pane", "dump", "--json"], responses: ["pane.dump": ok(dump)]),
        Case(arguments: ["pane", "split", "--direction", "right", "--run", "htop"], responses: ["pane.split": ok(panes)]),
        Case(arguments: ["pane", "split", "--no-focus"], responses: ["pane.split": ok(panes)]),
        Case(arguments: ["pane", "mirror", "--direction", "down"], responses: ["pane.mirror": ok(panes)]),
        Case(arguments: ["pane", "focus", "--pane", "2"], responses: ["pane.focus": ok(panes)]),
        Case(arguments: ["pane", "focus", "--direction", "left"], responses: ["pane.focus": ok(panes)]),
        Case(arguments: ["pane", "close", "--pane", "2", "--force"], responses: ["pane.close": ok("")]),
        Case(arguments: ["pane", "run", "ls"], responses: ["pane.run": ok("")]),
        Case(arguments: ["pane", "run", "--no-submit", "--", "git", "commit", "-h"], responses: ["pane.run": ok("")]),
        Case(arguments: ["pane", "run", "ls"], responses: ["pane.run": failure("read_only", "the pane is read-only", nil)]),
        Case(arguments: ["pane", "key", "ctrl+c"], responses: ["pane.key": ok("")]),
        Case(arguments: ["pane", "key", "escape", "--session", "macterm-api-8f327ce4a3f8"], responses: ["pane.key": ok("")]),
        Case(arguments: ["pane", "zoom"], responses: ["pane.zoom": ok(panes)]),
        Case(arguments: ["pane", "resize-split", "--axis", "horizontal", "--ratio", "0.3"], responses: ["pane.resize-split": ok("")]),
        Case(arguments: ["grid", "2x3"], responses: ["grid": ok(panes)]),
        // Sessions
        Case(arguments: ["session", "list"], responses: ["session.list": ok(sessions)]),
        Case(arguments: ["session", "list", "--json"], responses: ["session.list": ok(sessions)]),
        Case(arguments: ["session", "info", "macterm-api-8f327ce4a3f8"], responses: ["session.info": ok(sessions)]),
        Case(arguments: ["session", "kill", "macterm-api-8f327ce4a3f8"], responses: ["session.kill": ok("")]),
        // Layouts
        Case(arguments: ["layout", "apply", "--project", "api"], responses: ["layout.apply": ok("")]),
        Case(arguments: ["layout", "apply", "--force"], responses: ["layout.apply": ok("")]),
        Case(arguments: ["layout", "save", "--project", "api"], responses: ["layout.save": ok("")]),
        // Windows
        Case(arguments: ["window", "list"], responses: ["window.list": ok(windows)]),
        Case(arguments: ["window", "list", "--json"], responses: ["window.list": ok(windows)]),
        Case(arguments: ["window", "new"], responses: ["window.new": ok(windows)]),
        Case(arguments: ["window", "focus", "2"], responses: ["window.focus": ok(windows)]),
        Case(arguments: ["window", "close", "--window", "2"], responses: ["window.close": ok("")]),
        // Widgets
        Case(arguments: ["widget", "list"], responses: ["widget.list": ok(widgets)]),
        Case(arguments: ["widget", "list", "--json"], responses: ["widget.list": ok(widgets)]),
        Case(arguments: ["widget", "new", "--size", "3x3", "--run", "btop"], responses: ["widget.new": ok(widgets)]),
        Case(arguments: ["widget", "set", "1", "--size", "4x4"], responses: ["widget.set": ok(widgets)]),
        Case(arguments: ["widget", "edit", "1"], responses: ["widget.edit": ok(widgets)]),
        Case(arguments: ["widget", "done"], responses: ["widget.done": ok(widgets)]),
        Case(arguments: ["widget", "remove", "1"], responses: ["widget.remove": ok("")]),
        // Palettes and the tutorial
        Case(arguments: ["palette", "list"], responses: ["palette.list": ok(palettes)]),
        Case(arguments: ["palette", "list", "--json"], responses: ["palette.list": ok(palettes)]),
        Case(arguments: ["palette", "list"], responses: ["palette.list": ok(#""palettes":[]"#)]),
        Case(
            arguments: ["tutor", "project"],
            responses: ["tutor.render": ok(#""tutorial":{"topic":"project","text":"Welcome to projects.\nPress ⌘N for a tab."}"#)]
        ),
        // Failures
        Case(arguments: ["status"], responses: ["status": failure("starting", "Macterm is still starting", nil)]),
        Case(arguments: ["status"], responses: ["status": failure("internal", "something broke", "see the log")]),
        Case(
            arguments: ["pane", "list", "--project", "nope"],
            responses: ["pane.list": failure("not_found", "no project nope", "run: macterm project list")]
        ),
        // Bad arguments: nothing reaches the app
        Case(arguments: ["pane", "run", "ls", "-la"]),
        Case(arguments: ["nosuchverb"]),
        Case(arguments: ["tab", "rename"]),
        Case(arguments: ["palette", "exec"]),
        // Targets on the pane verbs
        Case(arguments: ["pane", "inspect", "--project", "api", "--tab", "2", "--pane", "1"], responses: ["pane.inspect": ok(inspect)]),
        Case(
            arguments: ["pane", "split", "--session", "macterm-api-8f327ce4a3f8", "--direction", "auto"],
            responses: ["pane.split": ok(panes)]
        ),
        Case(arguments: ["pane", "zoom", "--project", "api", "--tab", "1", "--pane", "2"], responses: ["pane.zoom": ok(panes)]),
        Case(arguments: ["pane", "list", "--project", "api", "--tab", "2"], responses: ["pane.list": ok(panes)]),
        Case(arguments: ["grid", "2x2", "--run", "htop", "--project", "api"], responses: ["grid": ok(panes)]),
        Case(arguments: ["tab", "select", "2", "--project", "api", "--window", "1"], responses: ["tab.select": ok(tabs)]),
        Case(arguments: ["widget", "new", "--name", "load"], responses: ["widget.new": ok(widgets)]),
        Case(arguments: ["pane", "dump"], responses: ["pane.dump": failure("no_surface", "the pane has no terminal yet", nil)]),
        Case(arguments: ["pane", "focus", "--pane", "1"], responses: ["pane.focus": failure("ambiguous", "2 panes match", nil)]),
        // `--no-focus` against an app that speaks protocol v1 is refused before anything is created
        Case(arguments: ["tab", "new", "--no-focus"], statusVersion: 1),
        Case(arguments: ["pane", "split", "--no-focus"], statusVersion: 1),
    ]

    @Test
    func every_argument_line_sends_and_prints_what_the_golden_file_says() throws {
        var recorded: [[String: Any]] = []
        for item in Self.cases {
            let socket = ContractSocket(responses: item.responses, version: item.statusVersion)
            defer { socket.stop() }
            let result = try socket.cli(item.arguments)
            let normalize = { (text: String) in socket.normalize(text) }
            var entry: [String: Any] = try [
                "arguments": item.arguments,
                "exit": Int(result.status),
                "stdout": normalize(result.stdout),
                "stderr": normalize(result.stderr),
                "requests": socket.requests.map { try Self.json($0) },
            ]
            if item.statusVersion != ControlProtocol.version { entry["appVersion"] = item.statusVersion }
            if !item.responses.isEmpty {
                entry["responses"] = item.responses.mapValues { (try? Self.object($0)) ?? $0 }
            }
            recorded.append(entry)
        }
        let data = try JSONSerialization.data(withJSONObject: recorded, options: [.prettyPrinted, .sortedKeys])
        try Self.compare(String(decoding: data, as: UTF8.self) + "\n", to: "cases.json")
    }

    // MARK: - Canned data

    private static func ok(_ data: String) -> String {
        data.isEmpty ? #"{"ok":true}"# : #"{"ok":true,"data":{\#(data)}}"#
    }

    private static func failure(_ code: String, _ message: String, _ action: String?) -> String {
        let hint = action.map { #","action":"\#($0)""# } ?? ""
        return #"{"ok":false,"error":{"code":"\#(code)","message":"\#(message)"\#(hint)}}"#
    }

    // swiftlint:disable line_length
    private static let projects = #""projects":[{"index":1,"id":"P1","name":"api","path":"/tmp/api","active":true,"loaded":true,"tabCount":2},{"index":2,"id":"P2","name":"web","path":"me@box:/srv/web","active":false,"loaded":false}]"#
    private static let tabs = #""tabs":[{"index":1,"id":"T1","title":"zsh","active":true,"paneCount":1},{"index":2,"id":"T2","title":"build","active":false,"paneCount":3}]"#
    private static let panes = #""panes":[{"index":1,"id":"A1","session":"macterm-api-8f327ce4a3f8","tabIndex":1,"tabID":"T1","title":"zsh","process":"vim","cwd":"/tmp/api","focused":true,"state":"running"},{"index":2,"id":"A2","session":"macterm-api-0a1b2c3d4e5f","tabIndex":1,"tabID":"T1","title":"zsh","focused":false}]"#
    private static let sessions = #""sessions":[{"name":"macterm-api-8f327ce4a3f8","clients":1,"leaderPID":777,"paneID":"A1"},{"name":"macterm-old-000000000000","clients":0}]"#
    private static let windows = #""windows":[{"index":1,"id":"W1","projectID":"P1","project":"api","focused":true},{"index":2,"id":"W2","focused":false}]"#
    private static let widgets = #""widgets":[{"index":1,"id":"G1","name":"load","session":"macterm-widget-1","size":"3x3","columns":3,"rows":3,"editing":false,"x":10,"y":20,"command":"btop"},{"index":2,"id":"G2","session":"macterm-widget-2","size":"2x2","columns":2,"rows":2,"editing":true,"x":0,"y":0}]"#
    private static let palettes = #""palettes":[{"id":"git/branches","file":"branches.yaml","name":"Git Branches","keybind":"cmd+shift+b"},{"id":"mine/broken","file":"broken.yaml","error":"line 3: no such key"}]"#
    private static let inspect = #""inspect":{"id":"A1","session":"macterm-api-8f327ce4a3f8","cols":120,"rows":40,"cellWidthPx":16,"cellHeightPx":34,"widthPx":1920,"heightPx":1360,"scrollbackTotal":500,"scrollbackOffset":460,"scrollbackLen":40,"altScreen":false,"contentScale":2,"foregroundPID":901,"foregroundArgv":["vim","a.txt"],"processExited":false,"needsConfirmQuit":true,"readOnly":false}"#
    private static let dump = #""dump":{"id":"A1","session":"macterm-api-8f327ce4a3f8","scrollback":false,"bytes":22,"text":"$ ls\nREADME.md  src\n$ "}"#
    // swiftlint:enable line_length

    // MARK: - Helpers

    private static func tree() throws -> [String: Any] {
        let dump = try BundledCLI.run(["--experimental-dump-help"], environment: helpEnvironment)
        #expect(dump.status == 0, "\(dump.stderr)")
        let object = try JSONSerialization.jsonObject(with: Data(dump.stdout.utf8))
        return try #require(object as? [String: Any])
    }

    /// The path of every command in the dump (the root is `[]`), depth first.
    private static func commandPaths(in dump: [String: Any]) -> [[String]] {
        let root = (dump["command"] as? [String: Any]) ?? dump
        var paths: [[String]] = []
        func walk(_ node: [String: Any], _ path: [String]) {
            paths.append(path)
            for child in node["subcommands"] as? [[String: Any]] ?? [] {
                if let name = child["commandName"] as? String { walk(child, path + [name]) }
            }
        }
        walk(root, [])
        return paths
    }

    private static func json(_ request: ControlRequest) throws -> Any {
        var copy = request
        copy.id = "-"
        let data = try JSONEncoder().encode(copy)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func object(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// Compares `text` with the golden file. A missing file is written and fails.
    private static func compare(_ text: String, to name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = goldenDirectory.appendingPathComponent(name)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("Golden/\(name) was missing and is written now. Review it and commit it.", sourceLocation: sourceLocation)
            return
        }
        #expect(
            text == existing,
            "The CLI no longer matches Golden/\(name). If the change is on purpose, delete the file, run this suite and review the diff.",
            sourceLocation: sourceLocation
        )
    }
}

/// A stand-in app: it records each request and answers a command with the
/// canned response for it, or with a bare ok.
private final class ContractSocket {
    let path = "/tmp/macterm-contract-\(UInt32.random(in: 0 ..< UInt32.max)).sock"
    private let home = "/tmp/macterm-contract-home-\(UInt32.random(in: 0 ..< UInt32.max))"
    private let server: ControlSocketServer
    private let received = LockedBox<[ControlRequest]>([])

    init(responses: [String: String], version: Int) {
        server = ControlSocketServer(socketPath: path)
        server.start()
        server.attach { [received, version] raw, _ in
            guard let request = try? ControlProtocol.decodeRequest(raw) else { return Data() }
            received.mutate { $0.append(request) }
            // The version probe of `--no-focus` is answered with a bare ok at the current version.
            let canned = responses[request.command] ?? #"{"ok":true}"#
            var object = (try? JSONSerialization.jsonObject(with: Data(canned.utf8))) as? [String: Any] ?? [:]
            object["v"] = version
            object["id"] = request.id
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(0x0A)
            return data
        }
    }

    var requests: [ControlRequest] { received.value }

    func stop() {
        server.stop()
    }

    func cli(_ arguments: [String]) throws -> BundledCLI.Result {
        try BundledCLI.run(arguments, environment: [
            ControlProtocol.socketEnvVar: path,
            "CFFIXED_USER_HOME": home,
            "HOME": home,
        ])
    }

    /// Replaces the paths of this run, which differ for each run.
    func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: path, with: "<socket>").replacingOccurrences(of: home, with: "<home>")
    }
}
