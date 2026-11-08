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
/// Remote panes (#104) still run v1's `zmx attach` on the REMOTE host
/// (`RemoteSpawn`); their teardown, foreground probe and orphan sweep go
/// over ssh from here.
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
    /// Tear down a session on a REMOTE host (#104), via
    /// `ssh -o BatchMode=yes … zmx kill <id>`. Best-effort: an unreachable
    /// host or auth failure logs and moves on (the session either detached
    /// with its dead ssh client or will be the user's to `zmx kill`).
    var killRemoteSession: @Sendable (_ remote: ProjectPath, _ sessionID: String, _ zmxPath: String?) async -> Void
    /// One batched foreground probe of a remote host (#104): session name →
    /// foreground (`comm` for tab naming, full command line for layout `run:`
    /// capture) for every `macterm-*` session there, via
    /// `RemoteSpawn.foregroundProbeArgv`. `zmxPath` (optional) is the explicit
    /// remote zmx path. Failures are classified (`RemoteProbeOutcome`) so the
    /// resolver can keep retrying a flaky link but suspend a host that
    /// refused our non-interactive auth (#272).
    var remoteForegrounds: @Sendable (_ remote: ProjectPath, _ zmxPath: String?) async -> RemoteProbeOutcome
    /// One stamp-then-list round trip for the remote orphan sweep (#281):
    /// re-assert `macterm.owner=<ownerID>` on every claimed session, then
    /// return the host's full listing (nil = probe failed → reap NOTHING).
    /// The caller (`AppState.sweepOrphanSessions`) judges the listing via
    /// `ZmxReaper.orphans(in:known:owner:)` and kills through
    /// `killRemoteSession`.
    var sweepRemoteOrphans: @Sendable (
        _ remote: ProjectPath,
        _ zmxPath: String?,
        _ sessionNames: [String],
        _ ownerID: String
    ) async -> [ZmxSessionListParser.Entry]?
    /// Every local v2 session from the server (`LocalSessions`), or nil when
    /// the server cannot be reached. nil means UNKNOWN: a caller never ends
    /// or restarts anything on it.
    var listSessions: @Sendable () async -> [LocalSession]?
    /// Ends v1's local zmx sessions of these names (`zmx kill`, in v1's
    /// socket folder), once, at the first v2 launch (design/008 §4). False
    /// when nothing was tried (no zmx, or the unit-test host).
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

        // Remote ops resolve `ssh` via PATH (through /usr/bin/env), NOT a
        // hardcoded /usr/bin/ssh: the PANE's own ssh is PATH-resolved (its
        // command runs through a shell), so ops must dial the same client —
        // a user on Homebrew OpenSSH gets consistent config/behavior across
        // both, and the e2e harness's ssh shim (its only route to a hermetic
        // ssh config, since OpenSSH resolves ~/.ssh/config via the user
        // record, not $HOME) covers background ops too.
        return ZmxClient(
            executableURL: resolveExecutable,
            isBundled: { bundledExecutable() != nil },
            killSession: { sessionID in
                // As `listSessions`: no server for the unit-test host.
                guard resolveExecutable() != nil else { return }
                await LocalSessions.shared.kill(sessionID)
            },
            killRemoteSession: { remote, sessionID, zmxPath in
                guard let argv = RemoteSpawn.opArgv(
                    remote: remote, zmxArguments: ["kill", sessionID], zmxPath: zmxPath
                )
                else { return }
                _ = await runZmx(
                    remoteSSHArgv(argv),
                    executable: remoteSSHExecutable,
                    timeout: .seconds(10)
                )
            },
            remoteForegrounds: { remote, zmxPath in
                guard let argv = RemoteSpawn.foregroundProbeArgv(remote: remote, zmxPath: zmxPath)
                else { return .unreachable }
                // The raw subprocess outcome, not the exit-zero-only wrapper:
                // classification needs ssh's stderr to tell a refused auth
                // (suspend the host, #272) from a flaky link (keep retrying).
                guard let outcome = await runZmxProcess(
                    remoteSSHArgv(argv),
                    executable: remoteSSHExecutable,
                    captureStdout: true,
                    timeout: .seconds(10)
                )
                else { return .unreachable }
                guard outcome.exitStatus == 0 else {
                    return RemoteProbeOutcome.classifyFailure(stderr: outcome.stderr)
                }
                return .success(RemoteForegroundResolver.parseProbeOutput(outcome.stdout))
            },
            sweepRemoteOrphans: { remote, zmxPath, sessionNames, ownerID in
                guard let argv = RemoteSpawn.orphanSweepArgv(
                    remote: remote, zmxPath: zmxPath,
                    sessionNames: sessionNames, ownerID: ownerID
                )
                else { return nil }
                // nil (spawn error / timeout / non-zero ssh exit) = UNKNOWN:
                // the caller reaps nothing.
                guard let stdout = await runZmx(
                    remoteSSHArgv(argv),
                    executable: remoteSSHExecutable,
                    captureStdout: true,
                    timeout: .seconds(10)
                )
                else { return nil }
                return ZmxSessionListParser.parse(stdout)
            },
            listSessions: {
                // The unit-test host starts no server (`ZmxBypass.unitTestHost`).
                guard resolveExecutable() != nil else { return nil }
                return await LocalSessions.shared.list()
            },
            endV1Sessions: { names in
                // The unit-test host ends nothing: its names are not v1's.
                guard resolveExecutable() != nil else { return false }
                guard !names.isEmpty else { return true }
                var env = ProcessInfo.processInfo.environment
                env["ZMX_DIR"] = ZmxSocketBudget.v1SocketDir(env: env)
                // `zmx kill` exits 1 when no session of the names runs.
                _ = await runZmxProcess(["kill"] + names, executable: bundledExecutable(), environment: env)
                return true
            }
        )
    }()

    /// See the PATH-resolution note above `return ZmxClient(` in `live`.
    private static let remoteSSHExecutable = URL(fileURLWithPath: "/usr/bin/env")
    private static func remoteSSHArgv(_ argv: [String]) -> [String] {
        ["ssh"] + argv
    }

    /// No-op client for tests / when zmx is unavailable.
    static let noop = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { _, _, _ in },
        remoteForegrounds: { _, _ in .unreachable },
        sweepRemoteOrphans: { _, _, _, _ in nil },
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

    /// Runs a zmx subcommand — directly (the bundled binary) or through ssh
    /// (remote ops pass `/usr/bin/ssh` and a `RemoteSpawn.opArgv`). Returns
    /// captured stdout on success, or nil on any failure (unbundled, spawn
    /// error, timeout, non-zero exit). Local callers use the non-budget-gated
    /// `bundledExecutable` so kill paths work even when this launch is over
    /// budget. Remote callers pass a longer `timeout`: ssh's ConnectTimeout
    /// alone can eat the local 5s budget.
    /// A completed subprocess: exit status plus both captured streams.
    /// Callers that only care about happy-path stdout use the `runZmx`
    /// wrapper; the probe path reads `exitStatus`/`stderr` itself to
    /// classify failures (`RemoteProbeOutcome`).
    private struct SubprocessOutcome {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
    }

    /// Exit-zero-only convenience over `runZmxProcess`: nil on spawn
    /// failure, timeout, or non-zero exit; stdout only when requested.
    private static func runZmx(
        _ arguments: [String],
        executable: URL?,
        captureStdout: Bool = false,
        timeout: Duration = subprocessTimeout
    ) async -> String? {
        guard let outcome = await runZmxProcess(
            arguments, executable: executable, captureStdout: captureStdout, timeout: timeout
        ), outcome.exitStatus == 0
        else { return nil }
        return captureStdout ? outcome.stdout : nil
    }

    private static func runZmxProcess(
        _ arguments: [String],
        executable: URL?,
        captureStdout: Bool = false,
        timeout: Duration = subprocessTimeout,
        environment: [String: String]? = nil
    ) async -> SubprocessOutcome? {
        guard let executable else { return nil }
        let commandDesc = "\(executable.lastPathComponent) " + arguments.joined(separator: " ")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        // macOS pipe buffer is ~64KB; a child that emits more without us draining
        // would deadlock on write while we await termination. Drain captured
        // stdout continuously, or send it to /dev/null when unneeded.
        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
        // Signals stdout EOF: the readabilityHandler yields once it sees the
        // empty chunk (pipe write-end fully closed). We await THIS (bounded) to
        // know the buffer holds the complete output — never a manual blocking
        // `availableData` drain, which has no timeout and would wedge this
        // cooperative-pool thread forever if a zmx descendant kept the write
        // end open past the parent's exit.
        let stdoutEOF: AsyncStream<Void>
        if captureStdout {
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            stdoutEOF = AsyncStream<Void> { continuation in
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    stdoutBuffer.withLock { $0.append(chunk) }
                }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            stdoutEOF = AsyncStream { $0.finish() }
        }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        // Same EOF signalling as stdout: `terminationHandler` can fire before
        // the last stderr chunk is delivered, and the probe path CLASSIFIES
        // failures by stderr content — a truncated "Permission denied" would
        // silently downgrade an auth refusal to a transient failure.
        let stderrEOF = AsyncStream<Void> { continuation in
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                stderrBuffer.withLock { $0.append(chunk) }
            }
        }

        // `terminationHandler` is the cancellation-safe exit signal; wired
        // BEFORE run() so the signal is never missed.
        let exitStream = AsyncStream<Int32> { continuation in
            process.terminationHandler = { proc in
                continuation.yield(proc.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            logger.warning("\(commandDesc, privacy: .public) failed: \(EnglishErrorText.describe(error), privacy: .public)")
            return nil
        }

        let exitStatus: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in exitStream {
                    return status
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            // `next()` yields Int32?? (group element is itself Int32?); flatten
            // to the inner status. First child to finish wins (timeout or exit).
            return await group.next().flatMap(\.self)
        }

        guard let exitStatus else {
            if process.isRunning { process.terminate() }
            // Wait for the kernel to reap before returning so we don't leak a
            // zombie. Bounded so a wedged SIGTERM target can't extend the path.
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in exitStream {} }
                group.addTask { try? await Task.sleep(for: .seconds(1)) }
                defer { group.cancelAll() }
                await group.next()
            }
            logger.warning("\(commandDesc, privacy: .public) timed out after \(timeout, privacy: .public)")
            return nil
        }
        if exitStatus != 0 {
            // Wait (bounded) for stderr EOF so the classification-bearing
            // tail has landed before we read the buffer.
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in stderrEOF {} }
                group.addTask { try? await Task.sleep(for: .seconds(1)) }
                defer { group.cancelAll() }
                await group.next()
            }
            let stderr = stderrBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
            logger.warning("\(commandDesc, privacy: .public) exit=\(exitStatus, privacy: .public) stderr=\(stderr, privacy: .public)")
            return SubprocessOutcome(exitStatus: exitStatus, stdout: "", stderr: stderr)
        }
        guard captureStdout else { return SubprocessOutcome(exitStatus: 0, stdout: "", stderr: "") }
        // `terminationHandler` can fire before the final `readabilityHandler`
        // chunk (and its EOF) have been delivered, so the buffer may still be
        // missing the tail. Wait for the handler's own empty-chunk EOF signal
        // rather than draining by hand — but bound the wait: if a zmx
        // descendant inherited and kept the stdout write end open, EOF never
        // arrives, and we must not block this thread forever. On timeout we
        // return whatever was buffered (the common case is tiny `zmx ls`
        // output already fully delivered before termination).
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stdoutEOF {} }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            defer { group.cancelAll() }
            await group.next()
        }
        let stdout = stdoutBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
        return SubprocessOutcome(exitStatus: 0, stdout: stdout, stderr: "")
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

/// Shared lexer for zmx's full (`ls`, non-`--short`) tab-delimited listing.
/// Each line is `[→ |  ]name=<name>\tk=v\t...`. Both `ZmxSessionListParser`
/// (client counts) and `ZmxForegroundResolver.parseLeaderPIDs` (leader pids)
/// consume this — one grammar, one tokenizer, so the two projections can't
/// drift.
enum ZmxListLexer {
    /// Parse one `ls` line into its `key=value` field map, or nil for lines
    /// that carry no fields. Strips the leading `→ ` current-session marker
    /// and any indentation before splitting on tabs.
    static func fields(in line: Substring) -> [Substring: Substring]? {
        var trimmed = line
        if trimmed.hasPrefix("→ ") { trimmed = trimmed.dropFirst(2) }
        while trimmed.first?.isWhitespace == true {
            trimmed = trimmed.dropFirst()
        }
        var values: [Substring: Substring] = [:]
        for field in trimmed.split(separator: "\t") {
            guard let separator = field.firstIndex(of: "=") else { continue }
            values[field[field.startIndex ..< separator]] = field[field.index(after: separator)...]
        }
        return values.isEmpty ? nil : values
    }

    /// Map each line's field map over the whole listing.
    static func forEachLine(_ stdout: String, _ body: ([Substring: Substring]) -> Void) {
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let values = fields(in: Substring(line)) else { continue }
            body(values)
        }
    }
}

/// Pure parser for zmx's full (`ls`, non-`--short`) tab-delimited listing.
/// Each line is `[→ |  ]name=<name>\tk=v\t...`; a healthy session carries
/// `clients=<n>`, an unreachable one carries `err=`/`status=` (no count).
enum ZmxSessionListParser {
    struct Entry: Equatable {
        var name: String
        /// nil when the count is unknown (err/status line); the reaper spares these.
        var clients: Int?
        /// The `macterm.owner` label value (#281), nil when absent — a session
        /// from another machine, another user, or one created before this
        /// installation ever stamped it. The remote reaper spares nil.
        var owner: String?

        init(name: String, clients: Int?, owner: String? = nil) {
            self.name = name
            self.clients = clients
            self.owner = owner
        }
    }

    static func parse(_ stdout: String) -> [Entry] {
        var entries: [Entry] = []
        ZmxListLexer.forEachLine(stdout) { values in
            guard let name = values["name"], name.hasPrefix(ZmxSessionName.prefix) else { return }
            // Absent `clients=` (err/status line) → nil = unknown, not zero.
            let clients = values["clients"].flatMap { Int($0) }
            let owner = values[Substring(RemoteSpawn.ownerLabelKey)].map(String.init)
            entries.append(Entry(name: String(name), clients: clients, owner: owner))
        }
        return entries
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

    /// Names safe to reap: a `macterm-` session with `clients == 0` that the
    /// `known` set doesn't claim, and that carries OUR `macterm.owner` label.
    /// Spares unknown counts (`clients == nil`), attached sessions, foreign
    /// prefixes, and anything still owned by a live/restored pane. A shared
    /// host legitimately parks zero-client `macterm-*` sessions belonging to
    /// other machines, so an unlabelled or foreign-owned session is spared
    /// unconditionally — the sweep only ever stamps names our own panes claim
    /// (`RemoteSpawn.orphanSweepScript`), which is what makes `owner == ours`
    /// mean "this installation created it and later failed to kill it".
    static func orphans(
        in entries: [ZmxSessionListParser.Entry],
        known: Set<String>,
        owner: String
    ) -> [String] {
        entries.compactMap { entry in
            guard entry.name.hasPrefix(ZmxSessionName.prefix),
                  entry.clients == 0,
                  !known.contains(entry.name),
                  entry.owner == owner
            else { return nil }
            return entry.name
        }
    }

    /// The claimed sessions that the listing shows WITHOUT our owner label,
    /// although the same sweep stamped them just before it listed. The stamp
    /// is `|| true`-guarded (`RemoteSpawn.orphanSweepScript`), so this is the
    /// only sign that it failed: the host's zmx is older than 0.7.0 (no `zmx
    /// set`, no labels in `zmx ls`), or the session's daemon is. The reaper
    /// spares such a session for ever. Only healthy lines count
    /// (`clients != nil`): an `err=` line carries no labels, and its daemon
    /// did not answer the stamp either.
    static func unstamped(
        in entries: [ZmxSessionListParser.Entry],
        claimed: [String],
        owner: String
    ) -> [String] {
        let claimedSet = Set(claimed)
        return entries.compactMap { entry in
            guard claimedSet.contains(entry.name),
                  entry.clients != nil,
                  entry.owner != owner
            else { return nil }
            return entry.name
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

/// zmx's leadership protocol (#345).
///
/// A session may have several attached clients but only one **leader**, whose
/// window size drives the pty; zmx drops a non-leader's resize outright. The
/// daemon hands leadership to any client that sends real user input, which
/// suits a human at a keyboard but gives Macterm no way to say "size the pty
/// from this pane" when the user merely clicks it — typing would reach their
/// running program.
///
/// So the client watches its stdin for this APC string and turns it into an
/// IPC Claim instead of forwarding it (zmx's `util.ClaimFilter`). APC because
/// no keyboard produces one and terminals discard unknown APC, so a stray
/// sequence reaching a program is inert.
enum ZmxLeadership {
    /// Must match `ClaimFilter.sequence` in the zmx fork exactly — it is a wire
    /// contract between the two, not a local constant.
    static let claimSequence = "\u{1b}_zmx;claim\u{1b}\\"
}

/// The foreground reports of the zmx fork (`src/foreground.zig` there, patch
/// 0010): a daemon that a client asked tells it which process group holds
/// the pty, before the first output that follows each change, and the
/// client writes the report into its output as an APC. libghostty raises
/// an APC it does not know as `GHOSTTY_ACTION_UNKNOWN_APC` (fork patch
/// 0020), and `Pane.receiveUnknownAPC` applies it as a foreground sample.
/// Both constants are a wire contract with the fork, not local choices.
///
/// Only a client started with the variable asks, so only Macterm's remote
/// panes get reports, and only from a host that runs the fork: an upstream
/// zmx ignores the request, the pane gets no report, and the ssh probe
/// (`RemoteForegroundResolver`) keeps naming it as before.
enum ZmxForegroundEvents {
    /// Exported by `RemoteSpawn.paneCommand` before `zmx attach`. The client
    /// removes it from its environment before the session starts.
    static let environmentVariable = "ZMX_FOREGROUND_EVENTS"

    /// `zmx;foreground;<idle>;<shell>;<comm>;<args>`: the host's idle
    /// verdict (the foreground is the session's own shell), its shell
    /// verdict (`comm` is in its `/etc/shells`; empty when it has none), the
    /// process name and the command line, which is last because it may
    /// contain `;`.
    static let reportPrefix = "zmx;foreground;"

    /// The report as a `RemoteForeground`, the same shape as one line of
    /// the probe, or nil for an APC that is not a report. Pure.
    nonisolated static func parse(_ payload: String) -> RemoteForeground? {
        guard payload.hasPrefix(reportPrefix) else { return nil }
        let fields = payload.dropFirst(reportPrefix.count)
            .split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        func flag(_ field: Substring) -> Bool? {
            switch field {
            case "1": true
            case "0": false
            default: nil
            }
        }
        guard let isIdle = flag(fields[0]) else { return nil }
        let comm = fields[2].trimmingCharacters(in: .whitespaces)
        guard !comm.isEmpty else { return nil }
        let args = fields[3].trimmingCharacters(in: .whitespaces)
        return RemoteForeground(comm: comm, isIdle: isIdle, isShell: flag(fields[1]), command: args.isEmpty ? nil : args)
    }
}

/// Resolves how a surface launches under zmx.
enum ZmxAttach {
    /// The `command-wrapper` argv that runs a surface's shell in its v2
    /// session: `[zmx, connect, macterm-<id>, --]`, put before ghostty's
    /// fully-resolved command, so the real shell (shell-integrated, under
    /// login(1)) is the session's command when the session is new, with the
    /// surface's folder and environment. A session that exists is attached,
    /// and the command is not run. Empty when `executablePath` is nil (zmx
    /// unbundled or over the socket-path budget) → the surface launches a
    /// plain, unpersisted shell.
    ///
    /// A declared `run:` is NOT folded in here — the surface types it into the
    /// wrapped shell via `initial_input`, preserving the same semantics as a
    /// non-persisted run.
    static func wrapperArgv(executablePath: String?, sessionID: String) -> [String] {
        guard let executablePath else { return [] }
        return [executablePath, "connect", sessionID, "--"]
    }
}
