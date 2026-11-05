import Foundation

/// The command line and output of a finished command, from the text of the
/// pane's screen.
///
/// libghostty reports that a command finished (OSC 133;D, with its exit code
/// and duration) but never says what the command was: the C API gives the
/// OSC 133 marks to no reader. The text comes from the screen instead, read
/// once the shell has printed its next prompt, with the prompt-mark rules of
/// `OutputExplanation.lastCommand(in:)`. When the screen does not show the
/// pair (a `clear`, a full-screen program, output longer than the screen,
/// a prompt with no mark), the result has no command: memory then records
/// only how the command ended. It never guesses.
///
/// A protocol, so that a fork patch which passes the command line on
/// `COMMAND_FINISHED` can replace the screen reading.
protocol CommandTextSource {
    func extract(screen: String) -> ExtractedCommand?
}

struct ExtractedCommand: Equatable {
    var command: String
    var output: String
    /// The user typed a space before the command: the shells'
    /// `HISTCONTROL=ignorespace` sign for "do not remember this".
    var isPrivate = false
}

struct ScreenCommandExtractor: CommandTextSource {
    func extract(screen: String) -> ExtractedCommand? {
        guard let last = OutputExplanation.lastCommand(in: screen) else { return nil }
        let command = last.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        // `lastCommand` trims the text after the prompt mark, so the leading
        // space is found on the line itself: the mark, its own space, then
        // one more before the command.
        var isPrivate = false
        if let mark = OutputExplanation.cursorPromptMark(in: screen) {
            let spaced = mark + "  " + command
            let tabbed = mark + " \t" + command
            isPrivate = screen.contains(spaced) || screen.contains(tabbed)
        }
        return ExtractedCommand(command: command, output: last.output, isPrivate: isPrivate)
    }

    /// The command on the prompt line where the cursor sits, read when the
    /// user presses Return: the last line of `screen` that is not empty,
    /// after its prompt mark. This is the one moment that a command which
    /// clears the screen (`clear`) or prints more than a screen is still on
    /// it. nil when that line has no prompt mark and command.
    ///
    /// The line ends at the cursor. What the shell draws after it is not the
    /// command: a right prompt (zsh `RPROMPT`, nushell's time) past a gap,
    /// or an autosuggestion (fish, zsh-autosuggestions) that Return does
    /// not accept. libghostty unwraps a line that wraps, and the cursor is
    /// on its last screen row, so `columns` turns the row's column into an
    /// index in the line. A Return pressed with the cursor in the middle of
    /// the command keeps the text before it only; `ProjectMemory.makeEntry`
    /// takes the rest from the screen when the command finishes.
    static func typedCommand(onScreen screen: String, cursorColumn: Int? = nil, columns: Int? = nil) -> ExtractedCommand? {
        guard var line = screen.split(separator: "\n").last(where: { !$0.allSatisfy(\.isWhitespace) }).map(String.init)
        else { return nil }
        if let cursorColumn, let columns, columns > 0 {
            let rowsAbove = max(0, (line.count - 1) / columns)
            let cut = rowsAbove * columns + cursorColumn
            if cut < line.count { line = String(line.prefix(cut)) }
        }
        guard let mark = OutputExplanation.promptMark(in: line),
              let command = OutputExplanation.command(in: line, after: mark)
        else { return nil }
        let isPrivate = line.contains(mark + "  ") || line.contains(mark + " \t")
        return ExtractedCommand(command: command, output: "", isPrivate: isPrivate)
    }

    /// Whether `screen`, the command as the screen shows it after the
    /// command finished, is `submitted` with the rest of a command that the
    /// cursor cut: a Return pressed in the middle of the line. A right
    /// prompt also makes the screen's command longer, past a gap of two or
    /// more spaces, and is not the command.
    static func screenCommand(_ screen: String, extends submitted: String) -> Bool {
        guard screen.count > submitted.count, screen.hasPrefix(submitted) else { return false }
        let rest = screen.dropFirst(submitted.count)
        return !rest.hasPrefix("  ") && !rest.hasPrefix(" \t")
    }

    /// Whether `screen`, the command as the screen shows it after the
    /// command finished, shows `command`: the same text, or the same text
    /// and a right prompt after a gap of two or more spaces. The output of
    /// the screen's command is then this command's output.
    static func screenCommand(_ screen: String, shows command: String) -> Bool {
        if QuickActionRanker.normalized(screen) == QuickActionRanker.normalized(command) { return true }
        guard screen.hasPrefix(command) else { return false }
        let rest = screen.dropFirst(command.count)
        return rest.hasPrefix("  ") || rest.hasPrefix(" \t")
    }

    /// The command in text that a program sent (`pane run`), without its
    /// line end.
    static func sentCommand(_ text: String) -> ExtractedCommand? {
        let line = text.trimmingCharacters(in: .newlines)
        let command = line.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ExtractedCommand(command: command, output: "", isPrivate: MemoryRedaction.isPrivate(line))
    }
}
