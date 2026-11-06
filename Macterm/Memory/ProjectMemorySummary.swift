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
            let key = QuickActionRanker.normalized(command)
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

/// A row of the panel's Next section: a command to run in a new split.
struct QuickAction: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Run the unresolved failure again.
        case retry
        /// A command the user runs often in this project.
        case frequent
        /// Derived from the git state.
        case git
        /// Chosen by the on-device model (`ProjectMemorySuggestions`).
        case suggested
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    /// An SF Symbol.
    var symbol: String
    var command: String
    /// Where the command runs; nil is the project's directory.
    var directory: String?

    var id: String { "\(kind)-\(command)" }
}

/// Ranks the panel's quick actions. Pure.
enum QuickActionRanker {
    static let limit = 6

    /// Commands that are not worth a button: moving around and looking.
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

    /// The weight of one run that finished at `date`: recent runs count more.
    static func weight(of date: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(date)
        switch age {
        case ..<3600: return 4
        case ..<86400: return 2
        case ..<(7 * 86400): return 1
        default: return 0.5
        }
    }

    static func actions(entries: [MemoryEntry], git: GitStatus?, now: Date = Date()) -> [QuickAction] {
        var actions: [QuickAction] = []
        var taken: Set<String> = []

        // A command with a masked secret cannot run again: the mask would
        // be typed in place of the secret.
        if let failure = ProjectMemorySummary.unresolvedFailure(in: entries), let command = failure.command,
           !isMasked(command)
        {
            actions.append(QuickAction(
                kind: .retry,
                title: String(localized: "Run Again"),
                subtitle: command,
                symbol: "arrow.clockwise",
                command: command,
                directory: failure.directory
            ))
            taken.insert(normalized(command))
        }

        if let git {
            if git.behind > 0 {
                actions.append(QuickAction(
                    kind: .git,
                    title: String(localized: "Pull"),
                    subtitle: String(localized: "\(git.behind) commits behind \(git.upstream ?? "upstream")"),
                    symbol: "arrow.down.circle",
                    command: "git pull"
                ))
            }
            if !git.isClean {
                actions.append(QuickAction(
                    kind: .git,
                    title: String(localized: "Show Changes"),
                    subtitle: String(localized: "\(git.changedFiles) changed files"),
                    symbol: "plusminus",
                    command: "git status"
                ))
            }
            if git.stashes > 0 {
                actions.append(QuickAction(
                    kind: .git,
                    title: String(localized: "Show Stashes"),
                    subtitle: String(localized: "\(git.stashes) stashes"),
                    symbol: "tray.full",
                    command: "git stash list"
                ))
            }
        }

        for score in frecency(entries, now: now)
            where actions.count < limit && !taken.contains(score.command) && !isMasked(score.command)
        {
            actions.append(QuickAction(
                kind: .frequent,
                title: score.command,
                subtitle: nil,
                symbol: score.last.outcome == .failure ? "xmark.circle" : "terminal",
                command: score.command,
                directory: score.last.directory
            ))
        }
        return Array(actions.prefix(limit))
    }

    struct Score {
        var command: String
        var score: Double
        /// The latest run.
        var last: MemoryEntry
    }

    /// Commands by frecency: the most weight first, then the most recent.
    static func frecency(_ entries: [MemoryEntry], now: Date) -> [Score] {
        var scores: [String: Score] = [:]
        for entry in entries {
            guard let command = entry.command, !isTrivial(command) else { continue }
            let key = normalized(command)
            var score = scores[key] ?? Score(command: key, score: 0, last: entry)
            score.score += weight(of: entry.finishedAt, now: now)
            score.last = entry
            scores[key] = score
        }
        return scores.values.sorted(by: ranksBefore)
    }

    private static func ranksBefore(_ lhs: Score, _ rhs: Score) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.last.finishedAt > rhs.last.finishedAt
    }
}
