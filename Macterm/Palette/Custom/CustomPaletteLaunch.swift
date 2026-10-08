import Foundation

/// How a palette's commands run — the way mise runs a task: POSIX `sh` with
/// errexit (`sh -o errexit -c`, mise's `unix_default_inline_shell_args`)
/// unless the command, leading whitespace aside, starts with `#!`, which runs
/// it as a script with that interpreter — `#!/usr/bin/env nu`, `python3`,
/// `node`. So a palette means the same thing whoever's login shell runs it,
/// and can be shared.
///
/// Every command is still started by the login shell, because its rc files
/// are the only place its PATH lives — `sh -l` reads `~/.profile`, which a
/// zsh or nu user's Homebrew PATH isn't in, and a `#!/usr/bin/env`
/// interpreter is found on that PATH too. (mise needs no such step: it runs
/// from the user's shell and inherits its environment; Macterm is launched by
/// launchd.) The login shell is handed one fixed line, `trampoline`, with the
/// command in an environment variable, so nothing in the command is ever
/// quoted into any shell's grammar. The line parses identically in nu, fish,
/// zsh and bash: its only syntax is a single-quoted string with no `'` or `\`
/// in it (`TextFileEditor`'s rule). Inside it `sh` reads the variable, unsets
/// it so the command's own children don't inherit it, and either execs
/// `sh -o errexit -c` on the command or writes it to a private temp file,
/// runs it, and removes it — `trap : INT` keeps the trampoline alive through
/// a ⌃C to the script so the file is still removed, while the script itself
/// gets the signal as usual.
enum CustomPaletteScript {
    static let commandVariable = "MACTERM_PALETTE_COMMAND"

    static let trampoline = #"/bin/sh -c 'c=$MACTERM_PALETTE_COMMAND; unset MACTERM_PALETTE_COMMAND; "#
        + ##"case $c in "#!"*) f=$(mktemp -t macterm-palette) || exit 1; printf %s "$c" >"$f"; chmod 700 "$f"; "##
        + #"trap : INT; "$f"; s=$?; rm -f "$f"; exit $s;; *) exec /bin/sh -o errexit -c "$c";; esac'"#

    /// The line the login shell runs for `command`, and what it needs added
    /// to the environment.
    static func invocation(of command: String) -> (line: String, environment: [String: String]) {
        (trampoline, [commandVariable: script(command)])
    }

    /// The command as it runs: leading whitespace dropped, as mise does, so
    /// an indented `#!` still names the interpreter.
    static func script(_ command: String) -> String {
        String(command.drop { $0.isWhitespace })
    }
}

/// How a palette's `run:` action starts in a new local pane without being
/// typed at its prompt, so it never reaches the shell's history: it runs
/// before the pane's shell, as the shell's parent, then gives way to it.
///
/// The palette puts the command in the new pane's environment
/// (`CustomPaletteScript.commandVariable`), which `Pane` hands to the surface
/// on its first build only — a reconnect respawn reattaches a session already
/// past it, and `PaneSnapshot` never persists a pane's environment — and the
/// surface puts `wrapperArgv` in front of the command libghostty resolved,
/// after zmx's own wrapper, so the session runs:
///
///     zmx attach <session> macterm palette exec <shell> <flags…> -- <resolved argv>
///
/// The resolved argv is ghostty's whole launch — `login(1)`, the shell, and
/// the shell-integration setup it already applied in the environment — and
/// `macterm palette exec` (`PaletteCommand.Exec`) runs the command through
/// `<shell> <flags…> <trampoline>`, takes the terminal back, and execs that
/// argv untouched: integration, cwd and the login shell are exactly what
/// they would have been.
///
/// The shell is the user's own, started **interactive** as well as login, so
/// the command sees every variable a typed one would — `zsh -l -c` reads
/// `.zprofile` but not `.zshrc`, where many users export PATH. An interactive
/// shell turns on job control and moves the terminal to its own process
/// group, and zsh and bash leave it there when they exit; the exec'd login
/// shell would then start in the background and stop. Taking the terminal
/// back (`tcsetpgrp`) is why the runner is a program, not a script.
enum CustomPaletteLaunch {
    /// Ends the runner's own arguments; the resolved argv follows.
    static let separator = "--"

    /// What starts `shell` running one command with the user's whole
    /// environment. Interactive login (`-i -l -c`) is understood by zsh,
    /// bash, fish, nu, xonsh, ksh and dash; the rest spell it their own way.
    static func flags(forShell shell: String) -> [String] {
        switch (shell as NSString).lastPathComponent {
        // csh reads `.cshrc`/`.tcshrc` for every shell, and takes `-l` only
        // as its sole argument.
        case "csh",
             "tcsh": ["-c"]
        // elvish takes no login or interactive flag.
        case "elvish": ["-c"]
        case "pwsh",
             "powershell": ["-Login", "-Interactive", "-Command"]
        default: ["-i", "-l", "-c"]
        }
    }

    /// The arguments put in front of the resolved command: the bundled CLI's
    /// runner, the shell to run the command through, and its flags.
    static func wrapperArgv(cli: String, shell: String) -> [String] {
        [cli, "palette", "exec", shell] + flags(forShell: shell) + [separator]
    }

    /// The runner's arguments read back: the shell and its flags, then the
    /// argv to exec. nil when they aren't in that shape.
    static func parse(_ arguments: [String]) -> (shell: [String], exec: [String])? {
        guard let split = arguments.firstIndex(of: separator), split > 0 else { return nil }
        let exec = Array(arguments[(split + 1)...])
        guard !exec.isEmpty else { return nil }
        return (Array(arguments[..<split]), exec)
    }
}
