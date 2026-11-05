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
    static func typedCommand(onScreen screen: String) -> ExtractedCommand? {
        guard let line = screen.split(separator: "\n").last(where: { !$0.allSatisfy(\.isWhitespace) }).map(String.init),
              let mark = OutputExplanation.promptMark(in: line),
              let command = OutputExplanation.command(in: line, after: mark)
        else { return nil }
        let isPrivate = line.contains(mark + "  ") || line.contains(mark + " \t")
        return ExtractedCommand(command: command, output: "", isPrivate: isPrivate)
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
