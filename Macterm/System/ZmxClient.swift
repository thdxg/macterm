import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxClient")

/// Per-surface session-persistence wrapper around the bundled `zmx` multiplexer
/// (https://github.com/neurosnap/zmx). Each terminal surface launches its shell
/// under `zmx attach <id>` (injected as ghostty's `command-wrapper`), so the
/// shell survives app quit; on the next launch the same session id re-attaches
/// to the still-running daemon and the buffer + process come back.
///
/// Cache-free by design: zmx itself is authoritative for attach-vs-create, so we
/// never gate launch on a stale local snapshot of daemon state. Adapted from
/// Supacode's `ZmxClient`, trimmed to Macterm's single-window model (no
/// per-worktree concept). Remote panes (#104) attach on the REMOTE host's
/// daemon — only their teardown flows through here (`killRemoteSession`);
/// listing/reaping stay local-only (see `reapOrphans`).
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
    /// foreground `comm` for every `macterm-*` session there, via
    /// `RemoteSpawn.foregroundProbeArgv`. `zmxPath` (optional) is the explicit
    /// remote zmx path. nil result = probe failed (unreachable / auth /
    /// timeout) — `RemoteForegroundResolver` degrades silently.
    var remoteForegroundComms: @Sendable (_ remote: ProjectPath, _ zmxPath: String?) async -> [String: String]?
    /// Each live Macterm session with its attached-client count, or nil when the
    /// probe failed/timed out. nil means UNKNOWN (never reap); `[]` is a
    /// successful empty listing. An entry's `clients == nil` marks an unknown
    /// count (err/status line) the reaper must also spare.
    var listSessionsWithClients: @Sendable () async -> [ZmxSessionListParser.Entry]?
    /// `macterm-…` session name → daemon session-leader pid, parsed from
    /// `zmx ls`. Feeds `ZmxForegroundResolver`'s cache so `ProcessInspector`
    /// can see past the `zmx attach` client to the real foreground process.
    /// Empty when the probe fails or no sessions exist.
    var sessionLeaderPIDs: @Sendable () async -> [String: pid_t]
}

extension ZmxClient {
    /// 5-second cap on any `zmx` subprocess so a stuck daemon never blocks the
    /// app's close / quit paths. Every call we issue (ls / kill) completes in
    /// <100ms in practice; if it doesn't, log + continue beats hanging.
    static let subprocessTimeout: Duration = .seconds(5)

    static let live: ZmxClient = {
        // Probe the socket-path budget once per process and cache the outcome.
        let probed = OSAllocatedUnfairLock<ProbeOutcome?>(initialState: nil)
        // The bundled binary at Contents/Resources/zmx/zmx (embed-zmx.sh).
        let cachedBundledURL: URL? = Bundle.main.url(
            forResource: "zmx",
            withExtension: nil,
            subdirectory: "zmx"
        )

        @Sendable
        func resolveExecutable() -> URL? {
            guard let url = cachedBundledURL else { return nil }
            let outcome: ProbeOutcome = probed.withLock { current in
                if let current { return current }
                let computed: ProbeOutcome
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    // The unit-test host is the full app: it boots, spawns the
                    // active project's panes, and then dies without the quit
                    // sweep — wrapping here would orphan a zmx daemon on every
                    // `mise run test`. Plain unpersisted shells under test.
                    computed = .bypass
                } else if let reason = ZmxSocketBudget.probe() {
                    logger.warning("Bypassing zmx wrapping: \(reason, privacy: .public)")
                    computed = .bypass
                } else {
                    computed = .allow
                }
                current = computed
                return computed
            }
            return outcome == .allow ? url : nil
        }

        @Sendable
        func bundledExecutable() -> URL? {
            cachedBundledURL
        }

        return ZmxClient(
            executableURL: resolveExecutable,
            isBundled: { bundledExecutable() != nil },
            killSession: { sessionID in
                _ = await runZmx(["kill", sessionID], executable: bundledExecutable())
            },
            killRemoteSession: { remote, sessionID, zmxPath in
                guard let argv = RemoteSpawn.opArgv(
                    remote: remote, zmxArguments: ["kill", sessionID], zmxPath: zmxPath
                )
                else { return }
                _ = await runZmx(
                    argv,
                    executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                    timeout: .seconds(10)
                )
            },
            remoteForegroundComms: { remote, zmxPath in
                guard let argv = RemoteSpawn.foregroundProbeArgv(remote: remote, zmxPath: zmxPath)
                else { return nil }
                guard let stdout = await runZmx(
                    argv,
                    executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                    captureStdout: true,
                    timeout: .seconds(10)
                )
                else { return nil }
                return RemoteForegroundResolver.parseProbeOutput(stdout)
            },
            listSessionsWithClients: {
                // nil from runZmx is the UNKNOWN signal (spawn error / timeout /
                // non-zero exit); preserve it so the reaper never kills on a
                // failed probe.
                guard let stdout = await runZmx(
                    ["ls"], executable: bundledExecutable(), captureStdout: true
                )
                else { return nil }
                return ZmxSessionListParser.parse(stdout)
            },
            sessionLeaderPIDs: {
                guard let stdout = await runZmx(
                    ["ls"], executable: bundledExecutable(), captureStdout: true
                )
                else { return [:] }
                return ZmxForegroundResolver.parseLeaderPIDs(stdout)
            }
        )
    }()

    /// No-op client for tests / when zmx is unavailable.
    static let noop = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { _, _, _ in },
        remoteForegroundComms: { _, _ in nil },
        listSessionsWithClients: { [] },
        sessionLeaderPIDs: { [:] }
    )

    private enum ProbeOutcome: Equatable { case allow, bypass }

    /// Kill every `macterm-*` session the live daemon hosts that no live/persisted
    /// pane claims and that has no attached client — i.e. crash / force-quit
    /// orphans. Attach-aware and prefix-scoped: a session with a live client
    /// (`clients > 0`), an unknown client count (`clients == nil`, an err/status
    /// line), or a non-`macterm-` name (e.g. a co-resident Supacode `supa-*`
    /// session) is spared, and a failed probe (`listSessionsWithClients` → nil)
    /// reaps nothing. `knownSessionNames` are the persisted session names every
    /// live + restored pane owns this launch (names are stored verbatim, never
    /// re-derived — see `ZmxSessionName`).
    ///
    /// LOCAL-ONLY by design, not oversight (#104): `listSessionsWithClients`
    /// probes the local daemon, so remote sessions never enter the orphan set.
    /// Reaping a remote host would be wrong even if we could — another
    /// machine's Macterm legitimately parks zero-client `macterm-*` sessions
    /// there, and we'd destroy them. Remote crash leftovers are the user's to
    /// `zmx kill` until sessions carry a per-installation marker.
    func reapOrphans(knownSessionNames: Set<String>) async {
        guard let live = await listSessionsWithClients() else {
            logger.info("Skipping orphan reap: zmx session probe unavailable")
            return
        }
        let orphans = ZmxReaper.orphans(in: live, known: knownSessionNames)
        guard !orphans.isEmpty else { return }
        logger.info("Reaping \(orphans.count, privacy: .public) orphan zmx session(s)")
        await withTaskGroup(of: Void.self) { group in
            for name in orphans {
                group.addTask { await self.killSession(name) }
            }
        }
    }

    /// Synchronously kill `sessionIDs`, blocking the caller until every kill
    /// finishes or `timeout` elapses. For `applicationWillTerminate`, where the
    /// run loop is tearing down and a detached `Task` would never be scheduled
    /// before the process exits — so a fire-and-forget kill silently no-ops. The
    /// kills run concurrently off the main thread; each is already bounded by the
    /// 5s subprocess timeout, and `timeout` caps the whole batch so a wedged
    /// daemon can't hang quit indefinitely.
    nonisolated func killSessionsBlocking(
        _ sessionIDs: [String],
        timeout: Duration = .seconds(6)
    ) {
        let kill = killSession
        runKillsBlocking(sessionIDs.map { id in { await kill(id) } }, timeout: timeout)
    }

    /// Remote counterpart of `killSessionsBlocking`, for the quit path's
    /// terminate-on-quit sweep. Longer default cap: each kill is an ssh
    /// round-trip (BatchMode, so it fails fast rather than prompting — an
    /// unreachable host just forfeits its kills when the cap lands).
    /// One remote session to tear down on quit: its host spec, session name,
    /// and the project's optional explicit zmx path.
    struct RemoteKill {
        let remote: ProjectPath
        let sessionID: String
        let zmxPath: String?
    }

    nonisolated func killRemoteSessionsBlocking(
        _ kills: [RemoteKill],
        timeout: Duration = .seconds(12)
    ) {
        let kill = killRemoteSession
        runKillsBlocking(
            kills.map { k in { await kill(k.remote, k.sessionID, k.zmxPath) } },
            timeout: timeout
        )
    }

    nonisolated private func runKillsBlocking(
        _ kills: [@Sendable () async -> Void],
        timeout: Duration
    ) {
        guard !kills.isEmpty else { return }
        let group = DispatchGroup()
        group.enter()
        Task {
            await withTaskGroup(of: Void.self) { taskGroup in
                for kill in kills {
                    taskGroup.addTask { await kill() }
                }
            }
            group.leave()
        }
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        _ = group.wait(timeout: .now() + seconds)
    }

    /// Runs a zmx subcommand — directly (the bundled binary) or through ssh
    /// (remote ops pass `/usr/bin/ssh` and a `RemoteSpawn.opArgv`). Returns
    /// captured stdout on success, or nil on any failure (unbundled, spawn
    /// error, timeout, non-zero exit). Local callers use the non-budget-gated
    /// `bundledExecutable` so kill paths work even when this launch is over
    /// budget. Remote callers pass a longer `timeout`: ssh's ConnectTimeout
    /// alone can eat the local 5s budget.
    private static func runZmx(
        _ arguments: [String],
        executable: URL?,
        captureStdout: Bool = false,
        timeout: Duration = subprocessTimeout
    ) async -> String? {
        guard let executable else { return nil }
        let commandDesc = "\(executable.lastPathComponent) " + arguments.joined(separator: " ")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Pin ZMX_DIR so the subprocess resolves the same socket dir as the
        // wrapped shell (defense-in-depth against env divergence).
        var env = ProcessInfo.processInfo.environment
        env["ZMX_DIR"] = ZmxSocketBudget.socketDir(env: env)
        process.environment = env

        // macOS pipe buffer is ~64KB; a child that emits more without us draining
        // would deadlock on write while we await termination. Drain captured
        // stdout continuously, or send it to /dev/null when unneeded.
        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
        if captureStdout {
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                stdoutBuffer.withLock { $0.append(chunk) }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.withLock { $0.append(chunk) }
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
            logger.warning("\(commandDesc, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
            let stderr = stderrBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
            logger.warning("\(commandDesc, privacy: .public) exit=\(exitStatus) stderr=\(stderr, privacy: .public)")
            return nil
        }
        guard captureStdout else { return nil }
        return stdoutBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
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

/// Pure parser for zmx's full (`ls`, non-`--short`) tab-delimited listing.
/// Each line is `[→ |  ]name=<name>\tk=v\t...`; a healthy session carries
/// `clients=<n>`, an unreachable one carries `err=`/`status=` (no count).
enum ZmxSessionListParser {
    struct Entry: Equatable {
        var name: String
        /// nil when the count is unknown (err/status line); the reaper spares these.
        var clients: Int?
    }

    static func parse(_ stdout: String) -> [Entry] {
        stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Entry? in
                var trimmed = Substring(line)
                if trimmed.hasPrefix("→ ") { trimmed = trimmed.dropFirst(2) }
                while trimmed.first?.isWhitespace == true {
                    trimmed = trimmed.dropFirst()
                }
                let fields = trimmed.split(separator: "\t")
                var values: [Substring: Substring] = [:]
                for field in fields {
                    guard let separator = field.firstIndex(of: "=") else { continue }
                    values[field[field.startIndex ..< separator]] = field[field.index(after: separator)...]
                }
                guard let name = values["name"], name.hasPrefix(ZmxSessionName.prefix) else { return nil }
                // Absent `clients=` (err/status line) → nil = unknown, not zero.
                let clients = values["clients"].flatMap { Int($0) }
                return Entry(name: String(name), clients: clients)
            }
    }
}

/// Pure orphan-selection logic, split out so the reap policy is unit-testable
/// without spawning subprocesses.
enum ZmxReaper {
    /// Names safe to reap: a `macterm-` session with `clients == 0` that the
    /// `known` set doesn't claim. Spares unknown counts (`clients == nil`),
    /// attached sessions (`clients > 0`), foreign-prefix sessions, and anything
    /// still owned by a live/restored pane.
    static func orphans(in entries: [ZmxSessionListParser.Entry], known: Set<String>) -> [String] {
        entries.compactMap { entry in
            guard entry.name.hasPrefix(ZmxSessionName.prefix),
                  entry.clients == 0,
                  !known.contains(entry.name)
            else { return nil }
            return entry.name
        }
    }
}

/// Socket-path budget against macOS' `sockaddr_un.sun_path` limit. If
/// `<ZMX_DIR>/<session-name>` would overflow, the bundled zmx is unusable and we
/// bypass wrapping (no persistence) rather than hand ghostty a command that dies
/// silently in `zmx attach`.
enum ZmxSocketBudget {
    static let sunPathLimit = 104
    static let safetyMargin = 2
    /// Worst-case `macterm-<slug>-<hex>` name (33 bytes with a full-length slug).
    static let sessionNameByteCount = ZmxSessionName.maxByteCount

    /// Resolved zmx socket dir: `ZMX_DIR`, then `XDG_RUNTIME_DIR`/zmx, then
    /// `TMPDIR`/zmx-<uid>, then `/tmp/zmx-<uid>`. Mirrors zmx's own resolver
    /// (incl. trailing-slash trim) so kill and the wrapped shell can't diverge.
    /// `env` is injectable for deterministic tests.
    static func socketDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
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
        let dir = socketDir(env: env)
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
    /// config, honored by `ZmxSocketBudget.socketDir`.
    static func scrubInheritedSession() {
        unsetenv("ZMX_SESSION")
    }
}

/// Resolves how a surface launches under zmx.
enum ZmxAttach {
    /// The `command-wrapper` argv that wraps a surface's shell in zmx:
    /// `[zmx, attach, macterm-<id>]`, prepended to ghostty's fully-resolved
    /// command so the real shell runs (and is shell-integrated) as a child of
    /// the wrapper. Empty when `executablePath` is nil (zmx unbundled or over the
    /// socket-path budget) → the surface launches a plain, unpersisted shell.
    ///
    /// A declared `run:` is NOT folded in here — the surface types it into the
    /// wrapped shell via `initial_input`, preserving the same semantics as a
    /// non-persisted run.
    static func wrapperArgv(executablePath: String?, sessionID: String) -> [String] {
        guard let executablePath else { return [] }
        return [executablePath, "attach", sessionID]
    }
}
