import ArgumentParser
import Darwin
import Foundation

/// `macterm palette` — the palettes of the installed extensions
/// (`~/.config/macterm/extensions/<id>/palettes/*.yaml`).
struct PaletteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "palette",
        abstract: "List the palettes of the installed extensions and show if Macterm can read each one.",
        subcommands: [List.self, Exec.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the palettes of the extensions in ~/.config/macterm/extensions with their name, state and any error."
        )

        @OptionGroup var options: ConnectionOptions

        func run() throws {
            try runControlCommand(command: "palette.list", args: ControlArgs(), options: options)
        }
    }

    /// `macterm palette exec <shell> <flags…> -- <argv…>` — Macterm's own,
    /// put in front of a new pane's command when a palette's `run:` action
    /// opens it (`CustomPaletteLaunch`). Runs the command in the pane's
    /// environment through the user's shell, takes the terminal back, then
    /// execs `<argv…>`, the pane's real launch, untouched.
    struct Exec: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the command of a palette action, then the shell of the pane. Macterm uses this command.",
            shouldDisplay: false
        )

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = []

        func run() throws {
            guard let launch = CustomPaletteLaunch.parse(arguments) else {
                Output.printError("palette exec: expected <shell> <flags…> -- <command…>")
                throw ExitCode(2)
            }
            if getenv(CustomPaletteScript.commandVariable) != nil {
                Self.runToCompletion(launch.shell + [CustomPaletteScript.trampoline])
            }
            // The trampoline consumed it in its own process; the shell that
            // follows must not see it.
            unsetenv(CustomPaletteScript.commandVariable)

            var cargs: [UnsafeMutablePointer<CChar>?] = launch.exec.map { strdup($0) }
            cargs.append(nil)
            execvp(launch.exec[0], cargs)
            Output.printError("palette exec: could not run \(launch.exec[0]): \(String(cString: strerror(errno)))")
            throw ExitCode(127)
        }

        /// Runs `argv` in the foreground and waits for it. ⌃C and ⌃\ are
        /// meant for the command, so the runner ignores them meanwhile — or
        /// interrupting a `kubectl logs -f` would close the pane — while the
        /// child gets them at their defaults. Then the terminal is taken back:
        /// an interactive shell moved it to its own process group.
        private static func runToCompletion(_ argv: [String]) {
            signal(SIGINT, SIG_IGN)
            signal(SIGQUIT, SIG_IGN)
            // ⌃Z would stop the command with no job control in front of it to
            // resume it — under bash and sh, a grandchild this runner can't
            // even see stop — freezing the pane until ⌃C. Off while the
            // command runs, so ⌃Z reaches it as a key; the shell that
            // follows gets the terminal's settings back.
            var saved = termios()
            let hasTerminal = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &saved) == 0
            if hasTerminal {
                var noSuspend = saved
                // `_POSIX_VDISABLE`, a macro Swift doesn't import: 0xFF here.
                withUnsafeMutableBytes(of: &noSuspend.c_cc) { chars in
                    chars[Int(VSUSP)] = 0xFF
                    chars[Int(VDSUSP)] = 0xFF
                }
                tcsetattr(STDIN_FILENO, TCSANOW, &noSuspend)
            }
            defer {
                signal(SIGINT, SIG_DFL)
                signal(SIGQUIT, SIG_DFL)
                if hasTerminal {
                    let previous = signal(SIGTTOU, SIG_IGN)
                    tcsetattr(STDIN_FILENO, TCSANOW, &saved)
                    signal(SIGTTOU, previous)
                }
            }

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var defaults = sigset_t()
            sigemptyset(&defaults)
            sigaddset(&defaults, SIGINT)
            sigaddset(&defaults, SIGQUIT)
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cargs.append(nil)
            var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { (cargs + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, argv[0], nil, &attributes, cargs, envp)
            if spawned == 0 {
                var status: Int32 = 0
                while true {
                    if waitpid(pid, &status, WUNTRACED) == -1 {
                        if errno == EINTR { continue }
                        break
                    }
                    // Stopped all the same (WIFSTOPPED) — a program that
                    // suspends itself, as an editor does on its own ⌃Z:
                    // nothing could resume it, so carry on, as bash does
                    // with a ⌃Z it can't use.
                    guard status & 0xFF == 0x7F else { break }
                    let foreground = tcgetpgrp(STDIN_FILENO)
                    kill(foreground > 0 ? -foreground : pid, SIGCONT)
                }
            } else {
                Output.printError("palette exec: could not start \(argv[0]): \(String(cString: strerror(spawned)))")
            }
            reclaimTerminal()
        }

        /// Makes the runner's process group the terminal's foreground again.
        /// Asking from the background raises SIGTTOU, hence the ignore.
        private static func reclaimTerminal() {
            guard isatty(STDIN_FILENO) != 0 else { return }
            let previous = signal(SIGTTOU, SIG_IGN)
            tcsetpgrp(STDIN_FILENO, getpgrp())
            signal(SIGTTOU, previous)
        }
    }
}
