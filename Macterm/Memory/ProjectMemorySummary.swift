import Foundation

/// What the memory panel says about a project: where the user left off.
/// Derived from the log and the git state alone, with no model. Pure.
struct ProjectMemorySummary: Equatable {
    /// When the last command in the project finished.
    var lastActivity: Date?
    /// The last command that has text.
    var lastCommand: MemoryEntry?
    /// A failure that is still the thing to fix
    /// (`unresolvedFailure(in:)`), or nil.
    var unresolvedFailure: MemoryEntry?
    /// The number of commands recorded.
    var commandCount: Int

    /// A pause this long between two commands ends a working stretch. A
    /// shorter gap is often time in an editor, where no command runs, so it
    /// is not a break: a failure is still the thing to fix after it.
    static let stretchBreak: TimeInterval = 3600

    /// The panel's "Summary is only available in a git repository" line shows only for a project
    /// with no command and no Git state, once a read has answered.
    static func showsGitOnlyNote(hasCommands: Bool, hasGitStateOrUnknown: Bool) -> Bool {
        !hasCommands && !hasGitStateOrUnknown
    }

    init(entries: [MemoryEntry]) {
        lastActivity = entries.last?.finishedAt
        lastCommand = entries.last { $0.command != nil }
        commandCount = entries.count
        unresolvedFailure = Self.unresolvedFailure(in: entries)
    }

    /// The latest open failure (`openFailures(in:)`): what the panel's
    /// card shows. The digest of the model, the suggestion candidates and
    /// the answer of Where Did I Leave Off read the same rule.
    static func unresolvedFailure(in entries: [MemoryEntry]) -> MemoryEntry? {
        let open = openFailures(in: entries)
        return entries.last { open.contains($0.id) }
    }

    /// The failures that are still the thing to fix: no later command with
    /// the same `MemoryCommand.retryKey` succeeded (a retry with options
    /// added, as `git clean` then `git clean -f`, fixes it), and no pause
    /// of `stretchBreak` or more came after it. A failure before the latest
    /// pause belongs to earlier work.
    static func openFailures(in entries: [MemoryEntry]) -> Set<UUID> {
        var succeeded: Set<String> = []
        var open: Set<UUID> = []
        var later: MemoryEntry?
        for entry in entries.reversed() {
            defer { later = entry }
            if let later, later.startedAt.timeIntervalSince(entry.finishedAt) >= stretchBreak { break }
            guard let command = entry.command else { continue }
            let key = MemoryCommand.retryKey(command)
            switch entry.outcome {
            case .success: succeeded.insert(key)
            case .failure: if !succeeded.contains(key) { open.insert(entry.id) }
            case .unknown: continue
            }
        }
        return open
    }

    /// `entries` without the failures that are not open. The model reads
    /// these: told about a failure that a retry fixed, it suggested the
    /// failed command again.
    static func withoutSettledFailures(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        let open = openFailures(in: entries)
        return entries.filter { $0.outcome != .failure || open.contains($0.id) }
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

    /// What a retry of `command` keeps: the words before its first option,
    /// when there are at least two (`git clean -f` and `git clean` have one
    /// key; `make test` and `make lint` do not). With fewer, an option comes
    /// before the subcommand (`python -m pytest`, `git -C repo push`), so
    /// the words do not name it: the key is the whole command.
    static func retryKey(_ command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace)
        let head = words.prefix { !$0.hasPrefix("-") }
        return (head.count >= 2 ? head : words[...]).joined(separator: " ")
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
