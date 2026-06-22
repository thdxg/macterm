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
/// per-worktree concept, no remote SSH surfaces).
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
    /// Each live Macterm session with its attached-client count, or nil when the
    /// probe failed/timed out. nil means UNKNOWN (never reap); `[]` is a
    /// successful empty listing. An entry's `clients == nil` marks an unknown
    /// count (err/status line) the reaper must also spare.
    var listSessionsWithClients: @Sendable () async -> [ZmxSessionListParser.Entry]?
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
                if let reason = ZmxSocketBudget.probe() {
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
            listSessionsWithClients: {
                // nil from runZmx is the UNKNOWN signal (spawn error / timeout /
                // non-zero exit); preserve it so the reaper never kills on a
                // failed probe.
                guard let stdout = await runZmx(
                    ["ls"], executable: bundledExecutable(), captureStdout: true
                )
                else { return nil }
                return ZmxSessionListParser.parse(stdout)
            }
        )
    }()

    /// No-op client for tests / when zmx is unavailable.
    static let noop = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        listSessionsWithClients: { [] }
    )

    private enum ProbeOutcome: Equatable { case allow, bypass }

    /// Kill every `macterm-*` session the live daemon hosts that no live/persisted
    /// pane claims and that has no attached client — i.e. crash / force-quit
    /// orphans. Attach-aware and prefix-scoped: a session with a live client
    /// (`clients > 0`), an unknown client count (`clients == nil`, an err/status
    /// line), or a non-`macterm-` name (e.g. a co-resident Supacode `supa-*`
    /// session) is spared, and a failed probe (`listSessionsWithClients` → nil)
    /// reaps nothing. `knownSurfaceIDs` are the surface ids every live + restored
    /// pane owns this launch.
    func reapOrphans(knownSurfaceIDs: Set<UUID>) async {
        guard let live = await listSessionsWithClients() else {
            logger.info("Skipping orphan reap: zmx session probe unavailable")
            return
        }
        let known = Set(knownSurfaceIDs.map(ZmxSessionID.make(surfaceID:)))
        let orphans = ZmxReaper.orphans(in: live, known: known)
        guard !orphans.isEmpty else { return }
        logger.info("Reaping \(orphans.count, privacy: .public) orphan zmx session(s)")
        await withTaskGroup(of: Void.self) { group in
            for name in orphans {
                group.addTask { await self.killSession(name) }
            }
        }
    }

    /// Runs a zmx subcommand; returns captured stdout on success, or nil on any
    /// failure (unbundled, spawn error, timeout, non-zero exit). Uses the
    /// non-budget-gated `bundledExecutable` so kill paths work even when this
    /// launch is over budget.
    private static func runZmx(
        _ arguments: [String],
        executable: URL?,
        captureStdout: Bool = false
    ) async -> String? {
        guard let executable else { return nil }
        let commandDesc = "zmx " + arguments.joined(separator: " ")
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
                try? await Task.sleep(for: subprocessTimeout)
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
            logger.warning("\(commandDesc, privacy: .public) timed out after \(subprocessTimeout)")
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

/// Pure session-ID helpers. zmx's macOS socket-path budget is tight (`sun_path`
/// is 104); `macterm-<UUID>` is 44 bytes, leaving headroom for a longer custom
/// `ZMX_DIR`.
enum ZmxSessionID {
    static let prefix = "macterm-"

    static func make(surfaceID: UUID) -> String {
        prefix + surfaceID.uuidString.lowercased()
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
                guard let name = values["name"], name.hasPrefix(ZmxSessionID.prefix) else { return nil }
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
            guard entry.name.hasPrefix(ZmxSessionID.prefix),
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
    /// `"macterm-" + 36-char UUID` is always 44 bytes; hardcoded so `probe`
    /// doesn't allocate a UUID per call just to count it.
    static let sessionNameByteCount = ZmxSessionID.prefix.utf8.count + 36

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

/// Resolves how a surface launches under zmx.
enum ZmxAttach {
    /// Launch plan for a surface, given the budget-gated zmx executable path
    /// (nil when zmx is unbundled or over budget) and the surface's session id.
    ///
    /// - Interactive surfaces (`command == nil`) keep a nil command and get an
    ///   argv `command-wrapper` (`[zmx, attach, id]`), so ghostty resolves +
    ///   integrates the real shell and zmx wraps the result.
    /// - Explicit commands (a declared `run:`) get a `zmx attach id /bin/sh -c
    ///   '<cmd>'` command string and no wrapper, matching the prior
    ///   `initial_input` semantics for declared runs.
    /// - A nil `executablePath` falls through to the raw command with no zmx.
    static func resolveLaunch(
        executablePath: String?,
        sessionID: String,
        command: String?
    ) -> (command: String?, commandWrapper: [String]) {
        // A blank command is "no command" (interactive); normalize so an empty
        // string can't slip into the script path and launch a bare shell.
        let command = command.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        guard let executablePath else { return (command, []) }
        if command == nil {
            return (nil, [executablePath, "attach", sessionID])
        }
        return (buildCommand(executablePath: executablePath, sessionID: sessionID, userCommand: command), [])
    }

    /// `zmx attach <id> /bin/sh -c '<cmd>'` for the declared-command path.
    static func buildCommand(executablePath: String, sessionID: String, userCommand: String?) -> String {
        let attach = "\(shellQuote(executablePath)) attach \(sessionID)"
        guard let command = userCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return attach
        }
        return "\(attach) /bin/sh -c \(shellQuote(command))"
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\''"))'"
    }
}
