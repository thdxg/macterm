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
    /// The commits on the current branch that the main branch does not
    /// have (`ProjectGit.branchLogScript`), newest first. Empty on a branch
    /// with no work of its own yet, and on the main branch itself. nil when
    /// it is not known: a detached HEAD, a repository with no main branch,
    /// or a read that failed.
    var branchCommits: [Commit]?
    /// The refs of the main branch that exist (`ProjectGit.mainRefPatterns`,
    /// with `origin/HEAD` resolved to its branch). Empty when not known.
    var mainRefs: [String] = []
    /// The paths with changes of any kind, in the order of `git status`.
    var changedPaths: [String] = []

    /// One file of the uncommitted diff, with its lines redacted.
    struct FileDiff: Equatable {
        var path: String
        /// The hunks: `@@` headers, context, `-` and `+` lines.
        var lines: [String]
    }

    /// The diff of the tracked files against HEAD (`ProjectGit.diffArguments`),
    /// in the order of git. Read only when a tracked file has changes
    /// (`hasTrackedChanges`); nil when it was not read or the read failed.
    /// Untracked files are only in `changedPaths`.
    var diff: [FileDiff]?

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

    /// The current branch is a main branch: a main ref names it. A
    /// `develop` that `origin/HEAD` names is one.
    var isOnMainBranch: Bool {
        guard let branch else { return false }
        return mainRefs.contains { $0 == "refs/heads/\(branch)" || ($0.hasPrefix("refs/remotes/") && $0.hasSuffix("/\(branch)")) }
    }

    /// Files with changes of any kind.
    var changedFiles: Int { staged + unstaged + untracked + conflicted }
    var isClean: Bool { changedFiles == 0 }
    /// A tracked file has changes, so there is a diff to read.
    var hasTrackedChanges: Bool { staged + unstaged + conflicted > 0 }
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
                // The path is after 8 fields, or after 9 for a rename, whose
                // old path follows a tab.
                if let path = field(line, after: line.first == "1" ? 8 : 9) {
                    status.changedPaths.append(String(path.prefix { $0 != "\t" }))
                }
            case "u":
                status.conflicted += 1
                if let path = field(line, after: 10) { status.changedPaths.append(String(path)) }
            case "?":
                status.untracked += 1
                status.changedPaths.append(String(line.dropFirst(2)))
            default:
                continue
            }
        }
        return status
    }

    /// The rest of `line` after `count` space-separated fields: a path,
    /// which can have spaces of its own.
    private static func field(_ line: Substring, after count: Int) -> Substring? {
        let fields = line.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
        return fields.count == count + 1 ? fields[count] : nil
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

    /// The output of `ProjectGit.branchLogScript`: the main refs, then the
    /// commits, then `end`. nil without the `end`: the read did not finish,
    /// and an empty list would claim that the branch has no work.
    static func parseBranchLog(_ text: String) -> (mainRefs: [String], commits: [GitStatus.Commit])? {
        var lines = text.split(separator: "\n").map(String.init)
        guard lines.last == "end" else { return nil }
        lines.removeLast()
        // `origin/HEAD` resolves to a ref that the list may have already.
        var mainRefs: [String] = []
        for line in lines where line.hasPrefix("refs/") && !mainRefs.contains(line) {
            mainRefs.append(line)
        }
        guard !mainRefs.isEmpty else { return nil }
        return (mainRefs, parseLog(lines.filter { !$0.hasPrefix("refs/") }.joined(separator: "\n")))
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
        worktreesOutput: String? = nil,
        branchLogOutput: String? = nil,
        diffOutput: String? = nil
    ) -> GitStatus {
        var status = parseStatus(statusOutput)
        if status.hasTrackedChanges, let diffOutput { status.diff = parseDiff(diffOutput) }
        if status.branch != nil { status.detachedAt = nil }
        status.recentCommits = logOutput.map(parseLog) ?? []
        if status.branch != nil, let branchLog = branchLogOutput.flatMap(parseBranchLog) {
            status.mainRefs = branchLog.mainRefs
            status.branchCommits = branchLog.commits
        }
        let worktrees = worktreesOutput.map(parseWorktrees) ?? [:]
        status.branches = (branchesOutput.map(parseBranches) ?? []).map { branch in
            var branch = branch
            branch.worktree = worktrees[branch.name]
            return branch
        }
        return status
    }

    // MARK: - Diff

    /// The most text of the diff that is kept, in characters. The digest
    /// has room for a small part of it; the rest is left out whole.
    static let diffCharacterLimit = 32000

    /// Lockfiles: generated, long, and say nothing about the work.
    static let lockfileNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
        "Cargo.lock", "Gemfile.lock", "Podfile.lock", "Package.resolved", "composer.lock", "poetry.lock",
        "Pipfile.lock", "uv.lock", "pdm.lock", "go.sum", "mix.lock", "flake.lock", "pubspec.lock", "deno.lock",
        "gradle.lockfile", "packages.lock.json", "mise.lock",
    ]

    /// Whether the diff of `path` stays out of the digest: a lockfile, or an
    /// `.env` file, which holds secrets by convention.
    static func isLeftOutOfDiff(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return lockfileNames.contains(name) || name.hasPrefix(".env")
    }

    /// The one line of a deleted file, in place of its hunks.
    static let deletedFileLine = "(the file is deleted)"

    /// `git diff HEAD` with `a/` and `b/` prefixes, one entry for each file
    /// with hunks; a deleted file has `deletedFileLine` alone. Every line goes through `MemoryRedaction`. A binary file,
    /// a file that `isLeftOutOfDiff`, a file with a private key block, and a
    /// file that would pass `diffCharacterLimit` are left out whole.
    static func parseDiff(_ text: String) -> [GitStatus.FileDiff] {
        var files: [GitStatus.FileDiff] = []
        var kept = 0
        for section in diffSections(text) {
            guard let file = fileDiff(section) else { continue }
            let size = file.lines.reduce(0) { $0 + $1.count + 1 }
            guard kept + size <= diffCharacterLimit else { continue }
            files.append(file)
            kept += size
        }
        return files
    }

    /// The lines of each file, split at its `diff --git` line.
    private static func diffSections(_ text: String) -> [[Substring]] {
        var sections: [[Substring]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                sections.append([line])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(line)
            }
        }
        return sections
    }

    private static func fileDiff(_ section: [Substring]) -> GitStatus.FileDiff? {
        var oldPath: String?
        var newPath: String?
        var hunks: [String] = []
        for line in section {
            if hunks.isEmpty, !line.hasPrefix("@@") {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { return nil }
                if line.hasPrefix("--- ") { oldPath = diffPath(line.dropFirst(4), prefix: "a/") }
                if line.hasPrefix("+++ ") { newPath = diffPath(line.dropFirst(4), prefix: "b/") }
                continue
            }
            // A private key is a secret as a whole: no rule masks its lines.
            if line.contains("PRIVATE KEY-----") { return nil }
            hunks.append(MemoryRedaction.redact(String(line)))
        }
        while hunks.last?.isEmpty == true {
            hunks.removeLast()
        }
        guard let path = newPath ?? oldPath, !hunks.isEmpty, !isLeftOutOfDiff(path) else { return nil }
        // The lines of a deleted file say nothing that its name does not,
        // and a long one would push every other file out of the budget.
        if newPath == nil { return GitStatus.FileDiff(path: path, lines: [deletedFileLine]) }
        return GitStatus.FileDiff(path: path, lines: hunks)
    }

    /// The path of a `---` or `+++` line. nil for `/dev/null` (an added or a
    /// deleted file). git ends a path that has a space with a tab, and
    /// quotes a path with a control character.
    private static func diffPath(_ value: Substring, prefix: String) -> String? {
        var value = String(value)
        if value.hasSuffix("\t") { value.removeLast() }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}
