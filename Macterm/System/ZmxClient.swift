import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxClient")

/// The session paths of Macterm's panes. A local pane is a v2 session of the
/// local server: its surface runs `zmx connect <id> -- <shell>` (injected as
/// ghostty's `command-wrapper`, `ZmxAttach`), which attaches to the session
/// or asks the server to make it, so the shell survives app quit and the
/// same id attaches again at the next launch. Listing and ending local
/// sessions go through the server (`LocalSessions`).
///
/// A remote pane is a session of its host's server (0057); its teardown
/// goes through `RemoteHosts`.
struct ZmxClient {
    /// Bundled zmx executable URL when the socket-path budget probe passed,
    /// otherwise nil. Use for the wrap-vs-bypass decision on NEW surfaces.
    var executableURL: @Sendable () -> URL?
    /// True whenever the zmx binary is bundled, independent of the probe.
    /// Kill paths use this (not `executableURL`) so we can still tear down
    /// sessions from an earlier under-budget launch even when this launch is
    /// over budget — probe bypass means "don't wrap", not "don't kill".
    var isBundled: @Sendable () -> Bool
    /// Tear down a session. No-op on a missing session. Bounded by the
    /// subprocess timeout so a stuck daemon can't hold the close path forever.
    var killSession: @Sendable (_ sessionID: String) async -> Void
    /// Tear down a session on a REMOTE host (#104), through the host's
    /// server (`RemoteHosts.endSession`). Best-effort: with no connection up
    /// it asks for no login, and the session stays.
    var killRemoteSession: @Sendable (_ remote: ProjectPath, _ sessionID: String, _ zmxPath: String?) async -> Void
    /// Every local v2 session from the server (`LocalSessions`), or nil when
    /// the server cannot be reached. nil means UNKNOWN: a caller never ends
    /// or restarts anything on it.
    var listSessions: @Sendable () async -> [LocalSession]?
    /// Ends v1's local zmx sessions of these names and their programs
    /// (`V1Sessions`), at the first v2 launch (design/008 §4). True only
    /// when none of them runs after it. False on the unit-test host, which
    /// tries nothing.
    var endV1Sessions: @Sendable (_ names: [String]) async -> Bool
}

extension ZmxClient {
    /// 5-second cap on any `zmx` subprocess so a stuck daemon never blocks the
    /// app's close / quit paths. Every call we issue completes in <100ms in
    /// practice; if it doesn't, log + continue beats hanging.
    static let subprocessTimeout: Duration = .seconds(5)

    static let live: ZmxClient = {
        // The bundled binary at Contents/Resources/zmx/zmx (embed-zmx.sh).
        let cachedBundledURL: URL? = Bundle.main.url(
            forResource: "zmx",
            withExtension: nil,
            subdirectory: "zmx"
        )

        @Sendable
        func resolveExecutable() -> URL? {
            guard let url = cachedBundledURL else { return nil }
            return liveBypass == nil ? url : nil
        }

        @Sendable
        func bundledExecutable() -> URL? {
            cachedBundledURL
        }

        return ZmxClient(
            executableURL: resolveExecutable,
            isBundled: { bundledExecutable() != nil },
            killSession: { sessionID in
                // As `listSessions`: no server for the unit-test host.
                guard resolveExecutable() != nil else { return }
                await LocalSessions.shared.kill(sessionID)
            },
            killRemoteSession: { remote, sessionID, _ in
                guard case let .remote(user, host, _) = remote else { return }
                let destination = RemoteSpawn.destination(user: user, host: host)
                await RemoteHosts.shared.endSession(sessionID, destination: destination)
            },
            listSessions: {
                // The unit-test host starts no server (`ZmxBypass.unitTestHost`).
                guard resolveExecutable() != nil else { return nil }
                return await LocalSessions.shared.list()
            },
            endV1Sessions: { names in
                // The unit-test host ends nothing: its names are not v1's.
                guard resolveExecutable() != nil else { return false }
                return await V1Sessions.end(names: Set(names), socketDir: ZmxSocketBudget.v1SocketDir())
            }
        )
    }()

    /// No-op client for tests / when zmx is unavailable.
    static let noop = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { _, _, _ in },
        listSessions: { [] },
        endV1Sessions: { _ in true }
    )

    /// Why this process starts new panes without zmx, or nil when it wraps
    /// them. Decided once per process, so `live.executableURL` and the
    /// Settings notice always agree.
    static var liveBypass: ZmxBypass? {
        liveBypassCache.withLock { cached in
            if let cached { return cached }
            let decided = bypass(environment: ProcessInfo.processInfo.environment)
            if case let .socketPathTooLong(reason) = decided {
                logger.warning("Bypassing zmx wrapping: \(reason, privacy: .public)")
            }
            cached = .some(decided)
            return decided
        }
    }

    private static let liveBypassCache = OSAllocatedUnfairLock<ZmxBypass??>(initialState: nil)

    /// The pure decision behind `liveBypass`.
    static func bypass(environment: [String: String]) -> ZmxBypass? {
        if environment["XCTestConfigurationFilePath"] != nil { return .unitTestHost }
        if let reason = ZmxSocketBudget.probe(env: environment) { return .socketPathTooLong(reason) }
        return nil
    }
}

/// Pure session-name helpers. Names are `macterm-<project-slug>-<short-hex>`
/// (#113: `zmx ls` should group readably by project, and a project's sessions
/// should be prefix-killable) — e.g. `macterm-macterm-3f9a2c1d4b7e`. The name
/// embeds the project name *at creation time*, so it is persisted verbatim in
/// the pane snapshot and never re-derived: renaming a project must not break
/// reattach. zmx's macOS socket-path budget is tight (`sun_path` is 104); the
/// name maxes out at 33 bytes, leaving headroom for a longer custom `ZMX_DIR`.
enum ZmxSessionName {
    static let prefix = "macterm-"
    static let maxSlugLength = 12
    static let shortHexLength = 12

    /// The quick terminal isn't a project; its sessions group under this slug.
    static let quickTerminalSlug = "quick"

    /// Desktop widgets aren't projects either (`DesktopWidget`).
    static let desktopWidgetSlug = "widget"

    static func make(projectName: String, paneSessionID: UUID) -> String {
        prefix + slug(projectName) + "-" + shortHex(paneSessionID)
    }

    /// Lowercased `[a-z0-9]` filter, truncated — readable in `zmx ls`, safe in
    /// a unix socket path. Non-ASCII project names may filter to nothing;
    /// "project" keeps the name well-formed (uniqueness comes from the hex).
    static func slug(_ name: String) -> String {
        let filtered = name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let truncated = String(filtered.prefix(maxSlugLength))
        return truncated.isEmpty ? "project" : truncated
    }

    /// First 12 hex digits of the pane's stable session UUID (48 bits —
    /// collision-free at any realistic pane count).
    static func shortHex(_ id: UUID) -> String {
        String(id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(shortHexLength))
    }

    /// Worst-case name length in bytes, for the socket-path budget probe.
    static var maxByteCount: Int {
        prefix.utf8.count + maxSlugLength + 1 + shortHexLength
    }

    /// Recover the slug from a persisted `macterm-<slug>-<hex12>` name, or nil
    /// when the name doesn't match our construction (foreign/corrupt). Used on
    /// restore so a split off a restored pane groups under the same project.
    static func slug(fromName name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let dash = body.lastIndex(of: "-") else { return nil }
        let slugPart = body[..<dash]
        let hexPart = body[body.index(after: dash)...]
        guard !slugPart.isEmpty,
              hexPart.count == shortHexLength,
              hexPart.allSatisfy(\.isHexDigit)
        else { return nil }
        return String(slugPart)
    }
}

/// Pure orphan-selection logic, split out so the reap policy is
/// unit-testable without a server or subprocesses.
enum ZmxReaper {
    /// Local sessions safe to end: a running `macterm-` session that no
    /// client shows (`clients == 0`) and that the `known` set doesn't claim.
    /// An unknown count (`clients == nil`) is spared. The runtime folder is
    /// this build flavor's own (`LocalServer.folderName`), so every session
    /// in it was made by an app of this flavor. These are the leftovers of a
    /// crash, or of a close whose kill did not reach the server.
    static func localOrphans(in sessions: [LocalSession], known: Set<String>) -> [String] {
        sessions.compactMap { session in
            guard session.isRunning,
                  session.name.hasPrefix(ZmxSessionName.prefix),
                  session.clients == 0,
                  !known.contains(session.name)
            else { return nil }
            return session.name
        }
    }
}

/// Why new panes start as plain shells, without `zmx connect`
/// (`ZmxClient.liveBypass`).
enum ZmxBypass: Equatable {
    /// The unit-test host is the full app: it boots, spawns the active
    /// project's panes, and then dies without the quit sweep, so wrapping
    /// would orphan a session on every `mise run test`. It also starts no
    /// server. This is on purpose, so Settings says nothing about it.
    case unitTestHost
    /// `<runtime dir>/<session-name>` would overflow `sun_path`
    /// (`ZmxSocketBudget.probe`). The payload is the reason for the log.
    case socketPathTooLong(String)
}

/// Socket-path budget against macOS' `sockaddr_un.sun_path` limit. If
/// `<runtime dir>/<session-name>` would overflow, no session can listen, and
/// we bypass wrapping (no persistence) rather than hand ghostty a command
/// that dies in `zmx connect`.
enum ZmxSocketBudget {
    static let sunPathLimit = 104
    static let safetyMargin = 2
    /// Worst-case `macterm-<slug>-<hex>` name (33 bytes with a full-length slug).
    static let sessionNameByteCount = ZmxSessionName.maxByteCount

    /// The v2 runtime directory, which holds the server's and the sessions'
    /// sockets (`LocalServer.runtimeDirectory`). nil when the environment
    /// names none.
    static func socketDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        LocalServer.runtimeDirectory(environment: env)?.path
    }

    /// v1's zmx socket dir: `ZMX_DIR`, then `XDG_RUNTIME_DIR`/zmx, then
    /// `TMPDIR`/zmx-<uid>, then `/tmp/zmx-<uid>`, as v1's zmx resolves it.
    /// Only the first v2 launch uses it, to end v1's sessions.
    static func v1SocketDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let custom = env["ZMX_DIR"], !custom.isEmpty { return custom }
        let uid = getuid()
        if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty { return "\(trimTrailingSlash(xdg))/zmx" }
        if let tmp = env["TMPDIR"], !tmp.isEmpty { return "\(trimTrailingSlash(tmp))/zmx-\(uid)" }
        return "/tmp/zmx-\(uid)"
    }

    private static func trimTrailingSlash(_ value: String) -> String {
        var trimmed = Substring(value)
        while trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    /// Non-nil reason when `<dir>/macterm-<UUID>` would not fit; nil = safe.
    static func probe(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let dir = socketDir(env: env) else { return "no runtime directory: HOME, TMPDIR and MACTERM_RUNTIME_DIR are unset" }
        let totalLen = dir.utf8.count + 1 + sessionNameByteCount
        let budget = sunPathLimit - safetyMargin
        if totalLen > budget {
            return "socket path \(totalLen)B exceeds budget \(budget)B (dir=\(dir))"
        }
        return nil
    }
}

/// Process-environment hygiene for zmx.
enum ZmxEnvironment {
    /// Drop the session marker inherited from whatever terminal launched the
    /// app. zmx exports `ZMX_SESSION=<name>` into every shell it wraps, so an
    /// app launched from inside a Macterm pane (`mise run run`) inherits the
    /// launcher pane's session identity and passes it to every surface it
    /// spawns — and `zmx attach` consults that parent session before creating
    /// the requested one, killing every new surface with `session "…" does
    /// not exist` once the launcher's session dies. The launcher's identity
    /// is never right for this process's own panes (zmx re-exports the
    /// correct value inside each wrapped shell), so scrub it before anything
    /// spawns. `ZMX_DIR` is deliberately kept — that's user socket-dir
    /// config, honored by `ZmxSocketBudget.v1SocketDir`.
    static func scrubInheritedSession() {
        unsetenv("ZMX_SESSION")
    }
}

/// One remote session's foreground, from the host's report
/// (`PaneChannelEvent.foreground`): the short process name (`comm`, feeds tab
/// naming), the host's own idle verdict (`isIdle`, feeds the busy-close
/// policy), and — when the host's `ps` gave it — the foreground's full
/// command line (`args`, feeds Save Layout's `run:` capture, the remote
/// analogue of the local KERN_PROCARGS2 argv).
struct RemoteForeground: Equatable {
    let comm: String
    /// The host's idle verdict — true when the tty's foreground process
    /// group IS the session leader's (the shell owns its prompt), judged
    /// where the processes actually live so no local shell database has to
    /// recognize a remote-only login shell. nil when the host could not say
    /// — consumers fall back to the local shell-database heuristic.
    let isIdle: Bool?
    /// The host's own shell verdict: whether `comm` is listed in the host's
    /// `/etc/shells`. nil when the host could not say (no `/etc/shells`) —
    /// consumers then fall back to the local shell database, which misses a
    /// shell only the host has.
    let isShell: Bool?
    /// The full `ps -o args=` command line, nil when the report carried
    /// none. May describe a shell at its prompt — `Pane.applyRemoteForeground`
    /// decides whether it counts as a running command.
    let command: String?

    /// `isIdle` and `isShell` default to nil (no host verdict) so
    /// name+command call sites — tests, the name-only convenience — read
    /// unchanged.
    init(comm: String, isIdle: Bool? = nil, isShell: Bool? = nil, command: String?) {
        self.comm = comm
        self.isIdle = isIdle
        self.isShell = isShell
        self.command = command
    }

    /// The session's `foreground` message. nil for a report with no name.
    init?(_ message: MactermProtocol.Foreground) {
        let comm = HostCheck.clean(String(decoding: message.comm.bytes, as: UTF8.self)).trimmingCharacters(in: .whitespaces)
        guard !comm.isEmpty else { return nil }
        let args = HostCheck.clean(String(decoding: message.args.bytes, as: UTF8.self)).trimmingCharacters(in: .whitespaces)
        self.init(comm: comm, isIdle: message.idle, isShell: message.shell, command: args.isEmpty ? nil : args)
    }
}
