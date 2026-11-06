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
    /// ran. A git command is kept only when the Git state supports it
    /// (`gitStateSupports`): with nothing in the log, the model padded the
    /// list with every allowed git command and a reason it made up (`git
    /// pull` "behind the remote" in a repository with no remote).
    static func actions(from suggestions: [OnDeviceModel.Suggestion], entries: [MemoryEntry], git: GitStatus? = nil) -> [QuickAction] {
        let known = Set(candidates(entries: entries) + safeGitCommands)
        var taken: Set<String> = []
        var actions: [QuickAction] = []
        for suggestion in suggestions {
            let command = QuickActionRanker.normalized(suggestion.command)
            guard known.contains(command), !taken.contains(command), gitStateSupports(command, git: git) else { continue }
            taken.insert(command)
            let last = entries.last { $0.command.map(QuickActionRanker.normalized) == command }
            actions.append(QuickAction(
                kind: .suggested,
                title: command,
                subtitle: suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                command: command,
                directory: last?.directory
            ))
            if actions.count == limit { break }
        }
        return actions
    }

    /// Whether the Git state gives a git command a reason: a pull needs
    /// commits behind, a fetch needs an upstream, status and diff need
    /// changes, a stash list needs stashes. A log always reads. A command
    /// that is not one of `safeGitCommands` is not judged here. With no Git
    /// state, nothing is refuted.
    static func gitStateSupports(_ command: String, git: GitStatus?) -> Bool {
        guard let git, safeGitCommands.contains(command) else { return true }
        switch command {
        case "git pull": return git.behind > 0
        case "git fetch": return git.upstream != nil
        case "git status",
             "git diff": return !git.isClean
        case "git stash list": return git.stashes > 0
        default: return true
        }
    }
}
