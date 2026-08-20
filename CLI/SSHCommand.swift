import ArgumentParser
import Foundation

/// `macterm ssh` — ghostty's `+ssh` action reimplemented natively (see
/// `SSHWrapper` for the full story). The one offline verb: it never touches
/// the control socket and works with no Macterm running.
///
/// Invoked two ways: by the bundled `ghostty` shim when the shell-integration
/// `ssh` wrapper fires (the `ssh-env`/`ssh-terminfo` features), and directly
/// by hand or alias (`alias ssh='macterm ssh --'`).
///
/// Flag names and defaults mirror `ghostty +ssh` so the shim is a straight
/// argument relay. One deliberate divergence: the cache is written right
/// after a successful install, not after the interactive ssh exits 0 — the
/// install succeeding is the fact being cached, and deferring loses it
/// whenever the session ends non-zero (a remote command exiting 1 would
/// force a pointless reinstall next connect). That is also what lets the
/// wrapper end in `execvp`, handing the tty to the real ssh with no wrapper
/// process lingering around the session.
struct SSHCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Run ssh with terminfo install and env forwarding (works without the app).",
        discussion: """
        Installs Macterm's bundled xterm-ghostty terminfo on the destination \
        on first connect (cached afterwards), sets TERM to what the host can \
        actually resolve, requests SendEnv forwarding for COLORTERM, \
        TERM_PROGRAM, and TERM_PROGRAM_VERSION, then replaces itself with the \
        real ssh. ssh's own flags and the destination pass through verbatim:

          macterm ssh user@example.com
          macterm ssh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
          macterm ssh --terminfo=false user@example.com

        This is the engine behind the shell-integration ssh wrapper (the \
        ssh-env / ssh-terminfo features), and mirrors `ghostty +ssh`.
        """
    )

    @Option(
        name: .customLong("forward-env"),
        help: "Set TERM and request SendEnv forwarding."
    )
    var forwardEnv: Bool = true

    @Option(help: "Install the bundled xterm-ghostty terminfo on first connect.")
    var terminfo: Bool = true

    @Option(help: "Use the terminfo install cache.")
    var cache: Bool = true

    @Option(
        name: .customLong("ssh"),
        help: "Path to the ssh binary. Default: first `ssh` on PATH."
    )
    var sshPath: String = "ssh"

    @Flag(help: "Print status lines to stderr.")
    var verbose = false

    @Argument(
        parsing: .captureForPassthrough,
        help: "Arguments passed to ssh verbatim (flags, destination, command)."
    )
    var sshArgs: [String] = []

    func run() throws {
        guard !sshArgs.isEmpty else {
            Output.printError("no ssh arguments provided")
            throw ExitCode(2)
        }

        // Which TERM we can honestly promise: the full entry only once it's
        // known to resolve on the destination (cached or just installed).
        var term = SSHWrapper.fallbackTerm
        if terminfo { term = settleTerminfo() }

        let argv = SSHWrapper.execArgv(
            ssh: sshPath,
            term: forwardEnv ? term : nil,
            sshArgs: sshArgs
        )
        verbosePrint("exec: \(argv.joined(separator: " "))")

        // Hand the tty to the real ssh. Only returns on failure.
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        execvp(argv[0], cargs)
        Output.printError("failed to run \(argv[0]): \(String(cString: strerror(errno)))")
        throw ExitCode(1)
    }

    /// The terminfo phase: resolve destination, consult the cache, install if
    /// needed. Returns the TERM to promise; every failure path warns and
    /// falls back to `xterm-256color` — this must never block a connection.
    private func settleTerminfo() -> String {
        guard let dest = resolveDestination() else {
            warn("could not resolve ssh destination; skipping terminfo install")
            return SSHWrapper.fallbackTerm
        }
        guard let source = terminfoSource(), !source.isEmpty else {
            warn("could not read the bundled \(SSHWrapper.entryName) terminfo; skipping install")
            return SSHWrapper.fallbackTerm
        }
        let version = SSHWrapper.versionKey(source: source)
        let cachePath = SSHWrapper.cacheFilePath(home: currentHome())

        if cache {
            let text = (try? String(contentsOfFile: cachePath, encoding: .utf8)) ?? ""
            if SSHWrapper.cacheContains(cacheText: text, destination: dest, version: version) {
                verbosePrint("dest: \(dest) (cached, skipping install)")
                return SSHWrapper.entryName
            }
            verbosePrint("dest: \(dest) (not cached, will install)")
        } else {
            verbosePrint("dest: \(dest) (cache disabled, will install)")
        }

        printToStderr("Setting up \(SSHWrapper.entryName) terminfo on \(dest)...")
        guard installTerminfo(source: source) else {
            warn("failed to install terminfo; continuing with \(SSHWrapper.fallbackTerm)")
            return SSHWrapper.fallbackTerm
        }
        if cache { writeCache(path: cachePath, destination: dest, version: version) }
        return SSHWrapper.entryName
    }

    /// `ssh -G <args>` → `user@hostname`. Local and instant; no watchdog.
    private func resolveDestination() -> String? {
        let argv = SSHWrapper.destinationArgv(ssh: sshPath, sshArgs: sshArgs)
        guard let out = runCapture(argv), let text = String(data: out, encoding: .utf8) else {
            return nil
        }
        return SSHWrapper.parseDestination(configDump: text)
    }

    /// The bundled entry as `tic`-compilable source. `TERMINFO` is pinned to
    /// the DB found beside this binary when there is one; otherwise the
    /// inherited environment stands (inside a pane, libghostty already pinned
    /// `TERMINFO` to the same bundled DB at shell spawn).
    private func terminfoSource() -> Data? {
        var environment: [String: String]?
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        if let db = SSHWrapper.bundledTerminfoDirectory(executablePath: executable) {
            var env = ProcessInfo.processInfo.environment
            env["TERMINFO"] = db
            environment = env
        }
        return runCapture(
            [SSHWrapper.infocmpPath] + SSHWrapper.sourceArgv(),
            environment: environment
        )
    }

    /// Pipe the source to a remote `tic -x -` over a throwaway ControlMaster
    /// (see `SSHWrapper.installArgv`). Interactive on purpose: this is the
    /// user's first connection, so auth prompts reach them via the tty.
    private func installTerminfo(source: Data) -> Bool {
        let controlPath = NSTemporaryDirectory()
            + "macterm-ssh-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        let argv = SSHWrapper.installArgv(
            ssh: sshPath, controlPath: controlPath, sshArgs: sshArgs, verbose: verbose
        )
        verbosePrint("exec: \(argv.joined(separator: " "))")
        return runCapture(argv, stdin: source, captureStdout: false, inheritStderr: verbose) != nil
    }

    private func writeCache(path: String, destination: String, version: String) {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = SSHWrapper.cacheUpdating(
            cacheText: text, destination: destination, version: version
        )
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            try Data(updated.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            verbosePrint("cache: wrote \(destination)")
        } catch {
            warn("unable to write the cache '\(path)': \(error.localizedDescription)")
        }
    }

    /// `$HOME`-env-first, like `ProjectPath.currentHome`: the hermetic
    /// harnesses isolate via the env var, which `NSHomeDirectory` ignores.
    private func currentHome() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// Run a process to completion via `/usr/bin/env` (so a bare `ssh`
    /// resolves through PATH exactly like the exec at the end). Returns
    /// captured stdout on exit 0, nil otherwise. Reads before waiting so a
    /// chatty child can't deadlock the pipe.
    private func runCapture(
        _ argv: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        captureStdout: Bool = true,
        inheritStderr: Bool = false
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let environment { process.environment = environment }

        let stdoutPipe = captureStdout ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        if !inheritStderr { process.standardError = FileHandle.nullDevice }
        let stdinPipe = stdin != nil ? Pipe() : nil
        if let stdinPipe { process.standardInput = stdinPipe }

        do {
            try process.run()
        } catch {
            return nil
        }
        if let stdinPipe, let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let out = stdoutPipe.flatMap { try? $0.fileHandleForReading.readToEnd() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return out ?? Data()
    }

    private func verbosePrint(_ message: String) {
        guard verbose else { return }
        printToStderr("+ssh: \(message)")
    }

    private func warn(_ message: String) {
        printToStderr("Warning: \(message)")
    }

    private func printToStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
