import Foundation

/// How a pane opens a text file in the user's terminal editor: one fixed line
/// typed into a fresh shell, with everything that varies passed in its
/// environment.
///
/// **Typed, not spawned**, because both inputs live in the user's shell and
/// nowhere else: `$EDITOR` is set by its rc file (`config.nu`, `.zshrc`), which
/// Macterm can't read from outside — a process's environment as the kernel
/// reports it is the one it was exec'd with, before the rc file ran — and an
/// editor like `hx` is found on the PATH that same rc file builds.
///
/// **Fixed, not formatted**, because the line must parse identically in every
/// login shell — nu, fish, zsh, bash. Its only shell syntax is a single-quoted
/// string handed to `sh`, which none of them interprets, and it contains no
/// `'` or `\` (the two characters fish's single quotes do interpret). The file,
/// the line and a configured command travel as environment variables, so a
/// path holding quotes, spaces or `$` needs no escaping in any shell's
/// grammar. `exec` makes the editor the pane's process: quitting it closes the
/// split or tab it opened in, and the leading space keeps the line out of the
/// history of shells that honor that (fish, zsh's `HIST_IGNORE_SPACE`, bash's
/// `ignorespace`).
///
/// An editor that isn't found says so and waits for Return rather than
/// closing the pane on its own error.
enum TextFileEditor {
    static let fileVariable = "MACTERM_EDITOR_FILE"
    static let lineVariable = "MACTERM_EDITOR_LINE"
    static let commandVariable = "MACTERM_EDITOR"

    static let typedCommand = #" exec sh -c 'e=${MACTERM_EDITOR:-${EDITOR:-vi}}; "#
        + #"command -v ${e%% *} >/dev/null || { echo "macterm: editor not found: $e"; read -r _; exit 1; }; "#
        + #"exec $e ${MACTERM_EDITOR_LINE:+"+$MACTERM_EDITOR_LINE"} "$MACTERM_EDITOR_FILE"'"#

    /// The environment that points `typedCommand` at `path`. `command` is the
    /// Settings value; empty (or blank) leaves the shell's `$EDITOR` in charge.
    /// The line goes to the editor as `+LINE`, the one position syntax vi,
    /// vim, nvim, helix, kakoune, emacs, nano and micro all accept.
    static func environment(path: String, line: Int?, command: String) -> [String: String] {
        var env = [fileVariable: path]
        if let line, line > 0 { env[lineVariable] = String(line) }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { env[commandVariable] = command }
        return env
    }
}
