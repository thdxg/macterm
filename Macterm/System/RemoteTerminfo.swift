import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteTerminfo")

/// Installs Macterm's own `xterm-ghostty` terminfo entry on a remote host, so
/// a remote pane's `RemoteSpawn.remoteTermPreamble` can settle on the full
/// entry instead of `xterm-256color`.
///
/// This is `ghostty +ssh`'s terminfo install reimplemented natively — no
/// ghostty binary involved. Macterm neither ships nor detects a `ghostty`
/// CLI, so depending on `+ssh` would make remote projects work only on
/// machines that also have Ghostty.app installed and new enough, and would
/// put a foreign auto-updating binary in the pane's spawn path. The pieces we
/// need are all already here: our bundled compiled entry, macOS's own
/// `/usr/bin/infocmp`, and `tic` on the far side. (The same reasoning later
/// produced `SSHWrapper`/`macterm ssh`, which serves the ssh the user types
/// into a *local* pane; this type serves panes whose connection Macterm
/// itself owns.)
///
/// **The source must be OUR bundled entry**, never the installed Ghostty.app's:
/// `TERM=xterm-ghostty` on the remote is a promise about what *our* surface
/// supports, and our surface is our pinned libghostty. Hence `infocmp` reads
/// `GhosttyApp.bundledTerminfoDirectory` (derived the same way libghostty
/// derives `TERMINFO`, see `GhosttyResourceResolver.terminfoDirectory`) rather
/// than inheriting this process's terminfo search path.
///
/// Two deliberate divergences from ghostty's implementation, both because our
/// remote panes have a different shape (the pane command IS the surface
/// command, with no shell wrapper in front of it):
/// - **Off the critical path.** Ghostty's install is synchronous inside the
///   `ssh` wrapper, riding the pane's own connection via `ControlMaster`,
///   because it *is* the connection being established. Ours is a separate
///   `BatchMode` op fired and forgotten: a host with no `tic`, a read-only
///   terminfo dir, or interactive-only auth then costs the pane nothing. It
///   can't, and must never, delay or fail a pane spawn — the host-side
///   `COLORTERM` export already guarantees truecolor without it.
/// - **The result is not cached to disk.** `remoteTermPreamble` asks the host
///   what it has at attach time rather than trusting a record of what we once
///   installed, so there is no cache to fall out of sync with reality. The
///   in-memory `attempted` set exists only to keep one app run from re-writing
///   the same host's terminfo on every pane spawn.
///
/// Gated on the user's own `ssh-terminfo` shell-integration flag, which
/// ghostty ships OFF — installing files on someone's server is not something
/// to start doing unasked, and reusing their existing flag keeps this out of
/// Macterm's own settings (ghostty-shaped settings belong in the ghostty
/// config).
enum RemoteTerminfo {
    /// The terminfo entry we install and the value `remoteTermPreamble` looks
    /// for. One constant so the installer and the preamble can never disagree
    /// about which name is being promised — delegated to `SSHWrapper` so the
    /// local ssh wrapper can't drift from it either.
    static let entryName = SSHWrapper.entryName

    /// macOS always ships these, so there is no probe and no fallback: both are
    /// in `/usr/bin` on every supported system (14+).
    static let infocmpPath = "/usr/bin/infocmp"

    /// argv for reading our bundled entry as `tic`-compilable source.
    /// `-x` keeps the extended capabilities — `Tc`/`RGB` among them, which is
    /// the whole point of installing it — and must match the flag `tic` gets.
    static func sourceArgv() -> [String] {
        ["-x", entryName]
    }

    /// The environment for the `infocmp` run: `TERMINFO` pinned to our bundled
    /// DB. Pinned rather than inherited because this process deliberately never
    /// sets `TERMINFO` (libghostty overwrites it at shell spawn — see
    /// `GhosttyApp.resolveResources`), so an inherited value would resolve
    /// against the *system* DB and either fail or, worse, silently ship some
    /// other ghostty's entry.
    static func sourceEnvironment(terminfoDirectory: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERMINFO"] = terminfoDirectory
        return env
    }

    /// argv (for `/usr/bin/ssh`) compiling the piped source on the remote.
    /// The same non-interactive profile as `RemoteSpawn.opArgv` — `BatchMode`
    /// so it can never hang on an auth prompt, `ConnectTimeout` so a dead host
    /// can't wedge the task — and `sh -c`-wrapped like every remote command so
    /// any login shell delivers it intact.
    ///
    /// `tic -x -` compiles from stdin into the user's own
    /// `~/.terminfo`/`$TERMINFO`, needing no privileges. nil for a local path.
    static func installArgv(remote: ProjectPath) -> [String]? {
        guard case let .remote(user, host, _) = remote else { return nil }
        let script = RemoteSpawn.assertSingleQuoteFree(
            RemoteSpawn.remoteEnvPreamble + "exec tic -x -",
            onViolation: .failNonZero
        )
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(RemoteSpawn.opConnectTimeoutSeconds)",
            RemoteSpawn.destination(user: user, host: host),
            "\(RemoteSpawn.remoteShell) \(RemoteSpawn.shellQuote(script))",
        ]
    }

    /// The destination key an install is deduped by: the same `user@host` the
    /// ssh commands target, so two projects on one host share one install and
    /// the same host reached as two different users doesn't.
    ///
    /// Deliberately NOT the project's directory — terminfo is per host+user,
    /// not per project. nil for a local path.
    static func destinationKey(remote: ProjectPath) -> String? {
        guard case let .remote(user, host, _) = remote else { return nil }
        return RemoteSpawn.destination(user: user, host: host)
    }
}

/// Drives `RemoteTerminfo` at remote-pane spawn: at most one install attempt
/// per destination per app run, fired and forgotten.
///
/// Every seam is injected so the gate and the dedupe are testable without a
/// host or a subprocess; `shared` wires the real ones.
@MainActor
final class RemoteTerminfoInstaller {
    static let shared = RemoteTerminfoInstaller(
        isEnabled: {
            // The user's own `ssh-terminfo` flag, read from their raw ghostty
            // config. Off by default in ghostty, so this installs nothing
            // until asked — writing files onto someone's server is not a
            // reasonable thing to start doing unprompted, and reusing their
            // existing flag keeps a ghostty-shaped setting out of Macterm's
            // own preferences.
            ShellIntegrationFeatures.isEnabled(
                "ssh-terminfo", inConfigText: MactermConfig.userGhosttyConfigText()
            )
        },
        terminfoDirectory: { GhosttyApp.shared.bundledTerminfoDirectory },
        install: { remote, terminfoDirectory in
            await RemoteTerminfoInstaller.runInstall(remote: remote, terminfoDirectory: terminfoDirectory)
        }
    )

    private let isEnabled: () -> Bool
    private let terminfoDirectory: () -> String?
    private let install: (ProjectPath, String) async -> Bool

    /// Destinations already attempted this run — the whole reason a cache
    /// exists here. It is NOT a record of what is installed: `remoteTermPreamble`
    /// asks the host what it has at attach time, so nothing downstream can be
    /// wrong because this set is stale. Keeping it in memory instead of on disk
    /// is what guarantees that.
    private var attempted: Set<String> = []

    init(
        isEnabled: @escaping () -> Bool,
        terminfoDirectory: @escaping () -> String?,
        install: @escaping (ProjectPath, String) async -> Bool
    ) {
        self.isEnabled = isEnabled
        self.terminfoDirectory = terminfoDirectory
        self.install = install
    }

    /// Make sure `remote` has our terminfo entry, for the benefit of the *next*
    /// session on that host — the pane being spawned right now already has its
    /// TERM settled by the time this finishes.
    ///
    /// Returns immediately and never throws: this must not delay or fail a pane
    /// spawn under any circumstances, because `remoteColorPreamble` already
    /// guarantees truecolor without it. A host with no `tic`, a read-only
    /// terminfo dir, or interactive-only auth (this op is `BatchMode`, so it
    /// cannot answer a prompt) simply logs and stays on `xterm-256color`.
    func ensureInstalled(remote: ProjectPath) {
        guard let key = RemoteTerminfo.destinationKey(remote: remote) else { return }
        guard isEnabled() else { return }
        guard let terminfoDirectory = terminfoDirectory() else {
            logger.debug("skipping terminfo install: no bundled terminfo dir resolved")
            return
        }
        // Insert BEFORE awaiting so simultaneous pane spawns on one host make a
        // single attempt. A failure deliberately stays recorded: retrying on
        // every spawn would mean an ssh connection per pane to a host that has
        // already told us no. The next launch tries again.
        guard attempted.insert(key).inserted else { return }
        Task { [install] in
            let ok = await install(remote, terminfoDirectory)
            logger.info("terminfo install for \(key, privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
        }
    }

    /// `infocmp -x xterm-ghostty` (against our bundled DB) piped to a remote
    /// `tic -x -`. nonisolated: process I/O has no business on the main actor.
    ///
    /// The source is ~4KB — far under the ~64KB pipe buffer — so writing it to
    /// ssh's stdin in one shot cannot block, and neither side needs the
    /// continuous draining a large transfer would (the trap `ZmxClient.runZmx`
    /// documents). Both stages are watchdogged anyway: `BatchMode` +
    /// `ConnectTimeout` bound the connect, and a terminate-on-deadline bounds
    /// everything after it, so a wedged host can't leave a process behind.
    nonisolated private static func runInstall(
        remote: ProjectPath, terminfoDirectory: String
    ) async -> Bool {
        guard let installArgv = RemoteTerminfo.installArgv(remote: remote) else { return false }
        guard let source = run(
            executable: RemoteTerminfo.infocmpPath,
            arguments: RemoteTerminfo.sourceArgv(),
            environment: RemoteTerminfo.sourceEnvironment(terminfoDirectory: terminfoDirectory),
            captureStdout: true
        ), !source.isEmpty
        else {
            logger.warning("infocmp produced no source for \(RemoteTerminfo.entryName, privacy: .public)")
            return false
        }
        return run(
            executable: "/usr/bin/ssh", arguments: installArgv, environment: nil, stdin: source
        ) != nil
    }

    /// Run a process to completion, returning captured stdout on success and
    /// nil on any failure (spawn error, watchdog kill, non-zero exit).
    nonisolated private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        captureStdout: Bool = false,
        stdin: Data? = nil
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdoutPipe = captureStdout ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        // Captured, not discarded: it's the only description of WHY an install
        // failed (no `tic`, unwritable terminfo dir, ssh auth refusing to
        // prompt under BatchMode), and this runs where the user can't see it.
        // Logged only on failure — a successful `tic` still chatters, e.g.
        // "older tic versions may treat the description field as an alias".
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stdinPipe = stdin != nil ? Pipe() : nil
        if let stdinPipe { process.standardInput = stdinPipe }

        do {
            try process.run()
        } catch {
            logger.warning("\(executable, privacy: .public) failed to spawn: \(error, privacy: .public)")
            return nil
        }

        // Bound the whole run: ssh's ConnectTimeout covers only the connect,
        // not a stalled transfer afterwards.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(20), execute: watchdog)
        defer { watchdog.cancel() }

        if let stdinPipe, let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        // Read before waiting: a child that fills the pipe while we wait for it
        // to exit would deadlock. Safe here only because the payload is small
        // and bounded either way by the watchdog.
        let out = stdoutPipe.flatMap { try? $0.fileHandleForReading.readToEnd() }
        let err = try? stderrPipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = err.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Assembled first, then logged as one interpolation: an
            // `OSLogMessage` can't be built by concatenating literals.
            let tool = (executable as NSString).lastPathComponent
            let message = "\(tool) exited \(process.terminationStatus): \(detail)"
            logger.warning("\(message, privacy: .public)")
            return nil
        }
        return out ?? Data()
    }
}
