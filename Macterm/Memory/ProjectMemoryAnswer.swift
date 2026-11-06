import Foundation

/// The answer to "where did I leave off in this project?", as one text for
/// Siri and Shortcuts (`GetMactermProjectMemoryIntent`). Pure.
///
/// The stored summary (`StoredSummary`, written by the on-device model
/// after a quiet period) is the answer when there is one. A command that
/// finished after the summary was written is not in it, so the latest
/// command follows the summary then. Without a summary, the facts alone
/// answer: the latest command with its result, and a command that failed
/// and did not succeed since (`ProjectMemorySummary.unresolvedFailure`).
///
/// The text is spoken, so it has no Markdown: the backticks that the model
/// puts around commands are dropped. The summary never says how long ago
/// things happened, so the facts do, relative to `now`.
enum ProjectMemoryAnswer {
    static func text(projectName: String, entries: [MemoryEntry], summary: StoredSummary?, now: Date = Date()) -> String {
        guard !entries.isEmpty else {
            return String(localized: "Nothing has run in \(projectName) yet.")
        }
        let facts = ProjectMemorySummary(entries: entries)
        if let summary, !summary.text.isEmpty {
            var text = summary.text.replacingOccurrences(of: "`", with: "")
            if let last = facts.lastCommand, last.finishedAt > summary.writtenAt {
                text += " " + lastCommandSentence(last, now: now)
            }
            return text
        }
        guard let last = facts.lastCommand else {
            let count = facts.commandCount
            let age = age(of: entries[entries.count - 1].finishedAt, now: now)
            return String(localized: "\(count) commands ran in \(projectName), the last one \(age).")
        }
        var text = lastCommandSentence(last, now: now)
        if let failure = facts.unresolvedFailure, failure.id != last.id, let command = failure.command {
            let code = failure.exitCode ?? 1
            text += " " + String(localized: "\(command) failed with exit code \(code) and has not succeeded since.")
        }
        return text
    }

    private static func lastCommandSentence(_ entry: MemoryEntry, now: Date) -> String {
        let command = entry.command ?? "?"
        let age = age(of: entry.finishedAt, now: now)
        switch entry.outcome {
        case .failure:
            let code = entry.exitCode ?? 1
            return String(localized: "The last command, \(command), failed with exit code \(code) \(age).")
        case .success:
            return String(localized: "The last command, \(command), succeeded \(age).")
        case .unknown:
            return String(localized: "The last command, \(command), ended \(age).")
        }
    }

    /// `5 minutes ago`, in the app language.
    static func age(of date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
