import Foundation

/// What the memory panel says about a project: where the user left off.
/// Derived from the log and the git state alone, with no model. Pure.
struct ProjectMemorySummary: Equatable {
    /// When the last command in the project finished.
    var lastActivity: Date?
    /// The last command that has text.
    var lastCommand: MemoryEntry?
    /// The latest run of a command that failed, with no later success of the
    /// same command: the thing the user probably still has to fix.
    var unresolvedFailure: MemoryEntry?
    /// The number of commands recorded.
    var commandCount: Int

    init(entries: [MemoryEntry]) {
        lastActivity = entries.last?.finishedAt
        lastCommand = entries.last { $0.command != nil }
        commandCount = entries.count
        unresolvedFailure = Self.unresolvedFailure(in: entries)
    }

    static func unresolvedFailure(in entries: [MemoryEntry]) -> MemoryEntry? {
        var succeeded: Set<String> = []
        for entry in entries.reversed() {
            guard let command = entry.command else { continue }
            let key = MemoryCommand.normalized(command)
            switch entry.outcome {
            case .success:
                succeeded.insert(key)
            case .failure:
                if !succeeded.contains(key) { return entry }
            case .unknown:
                continue
            }
        }
        return nil
    }
}

/// A row of the panel's Suggested section: a command that the on-device
/// model suggested, with its reason (`ProjectMemorySuggestions`). A click
/// types it into a new split.
struct QuickAction: Equatable, Identifiable {
    var title: String
    var subtitle: String?
    var command: String
    /// Where the command runs; nil is the project's directory.
    var directory: String?

    var id: String { command }
}

/// What the memory knows about a recorded command's text. Pure.
///
/// The panel's Suggested section was once filled from these too, when the
/// model gave nothing: the failed command again, git actions, and the
/// commands run most often. That put commands there only because they ran
/// recently, so the section now shows the model's suggestions or nothing,
/// as the summary does.
enum MemoryCommand {
    /// Commands that are not worth a suggestion: moving around and looking.
    static let trivialCommands: Set<String> = [
        "cd", "ls", "ll", "la", "l", "pwd", "clear", "cls", "exit", "logout", "z", "zi", "j", "history",
        "echo", "cat", "less", "more", "man", "which", "type", "true", "false", "reset", "source", ".",
        "open", "code", "hx", "vi", "vim", "nvim", "nano", "emacs", "subl", "macterm", "tldr",
    ]

    /// `command` with its spaces collapsed: two runs of one command count
    /// as one.
    static func normalized(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether redaction replaced a secret in `command`.
    static func isMasked(_ command: String) -> Bool {
        command.contains(MemoryRedaction.mask)
    }

    static func isTrivial(_ command: String) -> Bool {
        guard let first = command.split(whereSeparator: \.isWhitespace).first else { return true }
        return trivialCommands.contains(String(first))
    }
}
