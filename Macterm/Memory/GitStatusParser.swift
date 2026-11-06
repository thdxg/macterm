import Foundation

/// A project's git state, as the panel shows it.
struct GitStatus: Equatable {
    struct Commit: Equatable {
        var hash: String
        var subject: String
        var date: Date
    }

    /// The branch name, or nil on a detached HEAD.
    var branch: String?
    /// The short commit of a detached HEAD.
    var detachedAt: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicted = 0
    var stashes = 0
    /// Newest first.
    var recentCommits: [Commit] = []

    /// A local branch, with the worktree that has it checked out.
    struct Branch: Equatable {
        var name: String
        var hash: String
        var subject: String
        var lastCommit: Date
        /// The path of the worktree that has the branch checked out, or nil.
        var worktree: String?
    }

    /// The local branches with the latest commits, newest first, at most
    /// `ProjectGit.recentBranchCount`. The current branch is among them.
    var branches: [Branch] = []

    /// Files with changes of any kind.
    var changedFiles: Int { staged + unstaged + untracked + conflicted }
    var isClean: Bool { changedFiles == 0 }
}

/// Parses the output of the git commands that `ProjectGit` runs. Pure.
enum GitStatusParser {
    /// `git status --porcelain=v2 --branch --show-stash`.
    static func parseStatus(_ text: String) -> GitStatus {
        var status = GitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") {
                parseHeader(line.dropFirst(2), into: &status)
                continue
            }
            switch line.first {
            case "1",
                 "2":
                // `1 XY …` (changed) or `2 XY …` (renamed): X is the index,
                // Y the work tree, `.` is unchanged.
                let fields = line.split(separator: " ", maxSplits: 2)
                guard fields.count > 1, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                if xy[0] != "." { status.staged += 1 }
                if xy[1] != "." { status.unstaged += 1 }
            case "u":
                status.conflicted += 1
            case "?":
                status.untracked += 1
            default:
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ header: Substring, into status: inout GitStatus) {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid":
            if value != "(initial)" { status.detachedAt = String(value.prefix(7)) }
        case "branch.head":
            status.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // `+3 -1`
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        case "stash":
            status.stashes = Int(value) ?? 0
        default:
            break
        }
    }

    /// `git log -n --format=%h%x1f%s%x1f%ct`.
    static func parseLog(_ text: String) -> [GitStatus.Commit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 3, let seconds = TimeInterval(fields[2]) else { return nil }
            return GitStatus.Commit(
                hash: String(fields[0]),
                subject: String(fields[1]),
                date: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    /// `git for-each-ref refs/heads --sort=-committerdate
    /// --format=%(refname:short)%1f%(objectname:short)%1f%(committerdate:unix)%1f%(subject)`.
    static func parseBranches(_ text: String) -> [GitStatus.Branch] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return GitStatus.Branch(
                name: String(fields[0]),
                hash: String(fields[1]),
                subject: String(fields[3]),
                lastCommit: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    /// `git worktree list --porcelain`: the worktree path of each branch that
    /// a worktree has checked out.
    static func parseWorktrees(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var path: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path {
                result[String(line.dropFirst("branch refs/heads/".count))] = path
            } else if line.isEmpty {
                path = nil
            }
        }
        return result
    }

    /// Every output together. `detachedAt` is kept only on a detached HEAD.
    static func status(
        statusOutput: String,
        logOutput: String?,
        branchesOutput: String? = nil,
        worktreesOutput: String? = nil
    ) -> GitStatus {
        var status = parseStatus(statusOutput)
        if status.branch != nil { status.detachedAt = nil }
        status.recentCommits = logOutput.map(parseLog) ?? []
        let worktrees = worktreesOutput.map(parseWorktrees) ?? [:]
        status.branches = (branchesOutput.map(parseBranches) ?? []).map { branch in
            var branch = branch
            branch.worktree = worktrees[branch.name]
            return branch
        }
        return status
    }
}
