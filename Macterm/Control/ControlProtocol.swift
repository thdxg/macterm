import Foundation

/// Wire types for the Macterm control socket — the IPC contract between the
/// running app (`ControlSocketServer` + `ControlHandler`) and the bundled
/// `macterm` CLI. This file is compiled into BOTH targets (app and CLI) so
/// the codec can never drift; it must stay free of app-only dependencies
/// (AppKit, FileStorage, AppState).
///
/// Framing: one request per connection. The client writes a single
/// newline-terminated JSON `ControlRequest` line and half-closes its write
/// end; the server replies with a single newline-terminated JSON
/// `ControlResponse` line and closes. Newline-delimited JSON keeps the
/// protocol debuggable with `nc`/`socat` and leaves room for streaming later.
enum ControlProtocol {
    /// Bumped only for breaking changes; additive fields are always safe
    /// (both sides decode with optional fields).
    static let version = 1

    /// Socket file inside the app-support directory (per build flavor:
    /// `Macterm/` vs `Macterm Debug/`).
    static let socketFilename = "control.sock"

    /// Exported by the app into every spawned shell. A *hint*, not a pin:
    /// clients fall back to the well-known per-flavor paths when the hinted
    /// socket doesn't answer (a pinned stale path otherwise breaks every
    /// shell spawned before an app restart).
    static let socketEnvVar = "MACTERM_SOCKET"

    /// Injected per-pane so `macterm` invoked inside a pane can target the
    /// pane it runs in. Session names are restart-stable (persisted verbatim
    /// in the workspace snapshot), unlike pane UUIDs.
    static let sessionEnvVar = "MACTERM_SESSION"
}

// MARK: - Request

struct ControlRequest: Codable {
    var v: Int
    /// Client-generated; echoed in the response.
    var id: String
    /// Namespaced verb, e.g. `status`, `project.list`, `pane.list`.
    var command: String
    var args: ControlArgs?

    init(command: String, args: ControlArgs? = nil) {
        v = ControlProtocol.version
        id = UUID().uuidString
        self.command = command
        self.args = args
    }
}

/// Flat bag of every argument any command accepts (all optional). A single
/// struct instead of per-command payloads keeps the codec trivial and makes
/// unknown/extra fields harmless across versions — the same shape Zentty's
/// battle-tested `AgentIPCRequest` uses.
struct ControlArgs: Codable, Equatable {
    /// Project selector: name, UUID, or 1-based index as rendered by
    /// `project list`.
    var project: String?
    /// Tab selector: title, UUID, or 1-based index (`tab:3` or `3`).
    var tab: String?
    /// Pane selector: UUID or 1-based index within its tab.
    var pane: String?
    /// zmx session name (`macterm-<slug>-<hex12>`) — the restart-stable pane
    /// address.
    var session: String?
    /// Filesystem path (`project.create`).
    var path: String?
    /// Display name (`project.create`).
    var name: String?
    /// Also select/activate what was created (`project.create`).
    var select: Bool?
    /// Command to run: spawned via `initial_input` in new panes
    /// (`tab.new`, `pane.split`, `grid`), typed into the live shell for
    /// `pane.run`.
    var run: String?
    /// Split direction: `right`, `down`, or `auto`.
    var direction: String?
    /// Skip the busy-confirmation and destructive-plan guards
    /// (`tab.close`, `pane.close`, `layout.apply`).
    var force: Bool?
    /// Grid shape (`grid`).
    var rows: Int?
    var cols: Int?

    init(
        project: String? = nil,
        tab: String? = nil,
        pane: String? = nil,
        session: String? = nil,
        path: String? = nil,
        name: String? = nil,
        select: Bool? = nil,
        run: String? = nil,
        direction: String? = nil,
        force: Bool? = nil,
        rows: Int? = nil,
        cols: Int? = nil
    ) {
        self.project = project
        self.tab = tab
        self.pane = pane
        self.session = session
        self.path = path
        self.name = name
        self.select = select
        self.run = run
        self.direction = direction
        self.force = force
        self.rows = rows
        self.cols = cols
    }
}

// MARK: - Response

struct ControlResponse: Codable {
    var v: Int
    var id: String
    var ok: Bool
    var data: ControlData?
    var error: ControlError?

    static func success(id: String, data: ControlData? = nil) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: true, data: data, error: nil)
    }

    static func failure(id: String, error: ControlError) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: false, data: nil, error: error)
    }
}

struct ControlError: Codable, Equatable, Error {
    var code: ControlErrorCode
    var message: String
    /// Optional recovery hint shown to humans, e.g. "launch Macterm first".
    var action: String?
}

enum ControlErrorCode: String, Codable {
    /// The socket is up but AppState hasn't attached yet (app mid-launch).
    case starting
    case unknownCommand = "unknown_command"
    case badRequest = "bad_request"
    case notFound = "not_found"
    case ambiguous
    /// The operation was staged for user confirmation instead of executing
    /// (e.g. closing a busy tab without `--force`).
    case busy
    /// The target pane exists but its terminal surface hasn't been created.
    case noSurface = "no_surface"
    case internalError = "internal"
}

/// Union-of-optionals result payload (one struct for every command, like
/// Zentty's `AgentIPCResponseResult`): each command populates exactly the
/// fields it owns, and old clients ignore fields they don't know.
struct ControlData: Codable {
    var status: ControlStatusInfo?
    var projects: [ControlProjectInfo]?
    var tabs: [ControlTabInfo]?
    var panes: [ControlPaneInfo]?
    var sessions: [ControlSessionInfo]?

    init(
        status: ControlStatusInfo? = nil,
        projects: [ControlProjectInfo]? = nil,
        tabs: [ControlTabInfo]? = nil,
        panes: [ControlPaneInfo]? = nil,
        sessions: [ControlSessionInfo]? = nil
    ) {
        self.status = status
        self.projects = projects
        self.tabs = tabs
        self.panes = panes
        self.sessions = sessions
    }
}

struct ControlStatusInfo: Codable, Equatable {
    var version: String
    var pid: Int32
    var activeProject: String?
    var activeProjectID: String?
}

struct ControlProjectInfo: Codable, Equatable {
    var id: String
    var name: String
    var path: String
    var active: Bool
    /// Whether a live workspace exists for the project this launch.
    var loaded: Bool
    var tabCount: Int?
}

struct ControlTabInfo: Codable, Equatable {
    /// 1-based position in the sidebar, rendered as `tab:N`.
    var index: Int
    var id: String
    var title: String
    var active: Bool
    var paneCount: Int
}

struct ControlPaneInfo: Codable, Equatable {
    /// 1-based position within its tab (split-tree order), rendered `pane:N`.
    var index: Int
    var id: String
    /// zmx session name — the stable address for scripting.
    var session: String
    var tabIndex: Int
    var tabID: String
    var title: String
    /// Live foreground process name, if the poll has resolved one.
    var process: String?
    var cwd: String?
    var focused: Bool
}

struct ControlSessionInfo: Codable, Equatable {
    var name: String
    /// Attached client count from `zmx ls`; nil when the daemon reported the
    /// session in a state the parser couldn't count (err/status line).
    var clients: Int?
    /// Daemon leader pid, when resolved.
    var leaderPID: Int32?
    /// The live pane currently bound to this session, if any (a session with
    /// no pane is an orphan awaiting reap or reattach).
    var paneID: String?
}

// MARK: - Codec

extension ControlProtocol {
    static func encode(_ request: ControlRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    static func encode(_ response: ControlResponse) -> Data {
        // A response that fails to encode is a programming error; fall back to
        // a hand-built internal error so the client always gets valid JSON.
        if var data = try? JSONEncoder().encode(response) {
            data.append(0x0A)
            return data
        }
        let fallback = #"{"v":1,"id":"","ok":false,"error":{"code":"internal","message":"response encoding failed"}}"#
        return Data((fallback + "\n").utf8)
    }

    static func decodeRequest(_ data: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: trimmed(data))
    }

    static func decodeResponse(_ data: Data) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: trimmed(data))
    }

    /// Strip the trailing newline (and any stray whitespace) before decoding.
    private static func trimmed(_ data: Data) -> Data {
        var slice = data[...]
        while let last = slice.last, last == 0x0A || last == 0x0D || last == 0x20 {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}
