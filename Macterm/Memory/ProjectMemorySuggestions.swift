import Foundation

/// The commands that the panel's Suggested section offers, from what the
/// on-device model chose (`ProjectMemorySummarizer`). Pure.
///
/// **The model chooses and orders; it never invents a command that the
/// panel will run.** A click types the command into a shell, so a
/// suggestion is kept only when it is a command that ran in this project
/// (`candidates`), or one of `safeGitCommands`. Anything else the model
/// proposes is dropped. Without suggestions, the panel shows
/// `QuickActionRanker.actions` instead.
enum ProjectMemorySuggestions {
    static let limit = 5
    /// How many of the project's commands the model chooses from.
    static let candidateLimit = 30

    /// Git commands that read, or pull, and that the model may suggest
    /// although they never ran in the project.
    static let safeGitCommands = ["git status", "git pull", "git fetch", "git diff", "git log", "git stash list"]

    /// The commands the model may choose from: the project's own, newest
    /// first, with no duplicates, nothing trivial and nothing masked.
    static func candidates(entries: [MemoryEntry]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in entries.reversed() {
            guard let command = entry.command else { continue }
            let normalized = QuickActionRanker.normalized(command)
            guard !QuickActionRanker.isTrivial(normalized), !QuickActionRanker.isMasked(normalized), !seen.contains(normalized)
            else { continue }
            seen.insert(normalized)
            result.append(normalized)
            if result.count == candidateLimit { break }
        }
        return result
    }

    /// The model's suggestions as rows, in its order: only known commands,
    /// each one time, at most `limit`. The folder is where the command last
    /// ran.
    static func actions(from suggestions: [OnDeviceModel.Suggestion], entries: [MemoryEntry]) -> [QuickAction] {
        let known = Set(candidates(entries: entries) + safeGitCommands)
        var taken: Set<String> = []
        var actions: [QuickAction] = []
        for suggestion in suggestions {
            let command = QuickActionRanker.normalized(suggestion.command)
            guard known.contains(command), !taken.contains(command) else { continue }
            taken.insert(command)
            let last = entries.last { $0.command.map(QuickActionRanker.normalized) == command }
            actions.append(QuickAction(
                kind: .suggested,
                title: command,
                subtitle: suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                symbol: last?.outcome == .failure ? "xmark.circle" : "terminal",
                command: command,
                directory: last?.directory
            ))
            if actions.count == limit { break }
        }
        return actions
    }
}
