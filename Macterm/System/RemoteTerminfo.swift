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
///   `ssh` wrapper. Ours is a `command.run` request to the host's server
///   (`RemoteHosts.run`, 0058), sent when the host's link is ready and then
///   forgotten: a host with no `tic` or a read-only terminfo dir costs the
///   panes nothing. It can't, and must never, delay or fail a pane spawn —
///   the host-side `COLORTERM` export already guarantees truecolor without
///   it. It opens no connection and asks for no login.
/// - **The result is not cached to disk.** `remoteTermPreamble` asks the host
///   what it has at attach time rather than trusting a record of what we once
///   installed, so there is no cache to fall out of sync with reality. The
///   in-memory `attempted` set exists only to keep one app run from re-writing
///   the same host's terminfo on every connect.
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

    /// argv (for the host's `command.run`) that compiles `source` on the
    /// host. The source is `$1`, an argument and not stdin, because
    /// `command.run` gives the command no stdin; it is about 4 KB, far under
    /// the size limit of one argument.
    ///
    /// The command is `SSHWrapper.installCommand` in its verbose form, after
    /// the PATH preamble: `tic -x -o ~/.terminfo -` compiles from stdin into
    /// the user's own `~/.terminfo`, needing no privileges, and `infocmp`
    /// checks that the entry resolves. `-o` keeps a `tic` that runs as root
    /// out of the system database. Its stderr goes into the output, which
    /// the installer logs on a failure.
    static func installArgv(source: String) -> [String] {
        let script = RemoteSpawn.remoteEnvPreamble
            + "printf \"%s\" \"$1\" | { \(SSHWrapper.installCommand(verbose: true)); } 2>&1"
        return ["/bin/sh", "-c", script, "sh", source]
    }
}

/// Drives `RemoteTerminfo` when a host's link is ready (`RemoteHosts`): at
/// most one install attempt per destination per app run, fired and
/// forgotten.
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
        install: { destination, terminfoDirectory in
            await RemoteTerminfoInstaller.runInstall(destination: destination, terminfoDirectory: terminfoDirectory)
        }
    )

    private let isEnabled: () -> Bool
    private let terminfoDirectory: () -> String?
    private let install: (String, String) async -> Bool

    /// Destinations already attempted this run — the whole reason a cache
    /// exists here. It is NOT a record of what is installed: `remoteTermPreamble`
    /// asks the host what it has at attach time, so nothing downstream can be
    /// wrong because this set is stale. Keeping it in memory instead of on disk
    /// is what guarantees that.
    private var attempted: Set<String> = []

    init(
        isEnabled: @escaping () -> Bool,
        terminfoDirectory: @escaping () -> String?,
        install: @escaping (String, String) async -> Bool
    ) {
        self.isEnabled = isEnabled
        self.terminfoDirectory = terminfoDirectory
        self.install = install
    }

    /// Make sure `destination` (`user@host`: terminfo is per host and user,
    /// so two projects on one host share one install) has our terminfo
    /// entry, for the benefit of the *next* session on that host.
    ///
    /// Returns immediately and never throws: this must not delay or fail a pane
    /// spawn under any circumstances, because `remoteColorPreamble` already
    /// guarantees truecolor without it. A host with no `tic` or a read-only
    /// terminfo dir simply logs and stays on `xterm-256color`.
    func ensureInstalled(destination: String) {
        guard isEnabled() else { return }
        guard let terminfoDirectory = terminfoDirectory() else {
            logger.debug("skipping terminfo install: no bundled terminfo dir resolved")
            return
        }
        // Insert BEFORE awaiting so two connects to one host make a single
        // attempt. A failure deliberately stays recorded: retrying on every
        // connect would ask a host that has already told us no. The next
        // launch tries again.
        guard attempted.insert(destination).inserted else { return }
        Task { [install] in
            let ok = await install(destination, terminfoDirectory)
            logger.info("terminfo install for \(destination, privacy: .public): \(ok ? "ok" : "failed", privacy: .public)")
        }
    }

    /// `infocmp -x xterm-ghostty` (against our bundled DB), compiled on the
    /// host by its server. nonisolated: process I/O has no business on the
    /// main actor.
    nonisolated private static func runInstall(destination: String, terminfoDirectory: String) async -> Bool {
        guard let data = readSource(terminfoDirectory: terminfoDirectory),
              let source = String(data: data, encoding: .utf8), !source.isEmpty
        else {
            logger.warning("infocmp produced no source for \(RemoteTerminfo.entryName, privacy: .public)")
            return false
        }
        guard let result = await RemoteHosts.shared.run(
            // Under the 10 s that the app waits for a reply
            // (`LocalSessions.requestTimeout`), so a slow `tic` fails as a
            // time-out on the host and is not logged as a failure that
            // succeeded.
            RemoteTerminfo.installArgv(source: source), destination: destination, timeout: .seconds(8)
        )
        else { return false }
        guard result.code == 0 else {
            // The host's text, without its control characters.
            let detail = HostCheck.clean(String(decoding: result.output.bytes, as: UTF8.self))
            logger.warning("tic on \(destination, privacy: .public) failed: \(detail, privacy: .public)")
            return false
        }
        return true
    }

    /// `infocmp`'s output, or nil on any failure (spawn error, watchdog
    /// kill, non-zero exit).
    nonisolated private static func readSource(terminfoDirectory: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteTerminfo.infocmpPath)
        process.arguments = RemoteTerminfo.sourceArgv()
        process.environment = RemoteTerminfo.sourceEnvironment(terminfoDirectory: terminfoDirectory)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.warning("infocmp failed to spawn: \(error, privacy: .public)")
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(20), execute: watchdog)
        defer { watchdog.cancel() }
        // Read before waiting: a child that fills the pipe while we wait for
        // it to exit would deadlock. The entry is about 4 KB.
        let out = try? stdoutPipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.warning("infocmp exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return out ?? Data()
    }
}
