import Foundation

/// Reads a project's git state for the memory panel: locally, or through
/// the host's server for a remote project (`remoteStatus`).
///
/// **Never the `/usr/bin/git` shim on a Mac without the Command Line Tools**:
/// it opens the install dialog (see `GitWorktrees`). `executable` takes a git
/// that is really there: Homebrew's, or the one in the developer directory
/// that `xcode-select -p` names. With none, the panel shows no git state.
///
/// Each run has a timeout, sets `GIT_OPTIONAL_LOCKS=0` so that a read never
/// takes the index lock from the user's own git, and turns the fsmonitor
/// off: a daemon that it starts could hold the output pipe open.
///
/// A fifth read, `branchLogScript`, lists the commits of the current
/// branch that the main branch does not have. The latest commits of HEAD
/// cannot tell them apart: on a new branch they are mostly the main
/// branch's own history, and the summary named that as the user's work.
///
/// A sixth read, `diffArguments`, runs only when a tracked file has changes:
/// the diff of the uncommitted work, so that the summary can say what
/// changed in the files and not only which files. A clean tree reads no
/// diff, and the diff of a commit is never read: its subject is in the
/// digest already.
///
/// A remote read is one `command.run` request to the host's server, over
/// the host's one connection (`RemoteHosts.run`, 0058). It runs the same six
/// commands on the host (`RemoteSpawn.gitProbeScript`), with the outputs
/// separated by `recordSeparator`. It never asks for a login: with no
/// connection up, nothing is read.
enum ProjectGit {
    static let timeout: Duration = .seconds(5)
    /// The time limit of a remote read on the host.
    static let remoteTimeout: Duration = .seconds(8)
    static let recentCommitCount = 5
    static let recentBranchCount = 6
    /// Between the six outputs of a remote read (ASCII record separator).
    static let recordSeparator: Character = "\u{1E}"

    /// The git state of the repository at `path`, or nil when it is not in
    /// a repository or no usable git is installed.
    static func status(at path: String) async -> GitStatus? {
        guard let git = resolvedExecutable else { return nil }
        guard let statusOutput = await run(git, ["status", "--porcelain=v2", "--branch", "--show-stash"], in: path) else {
            return nil
        }
        let logOutput = await run(git, ["log", "-\(recentCommitCount)", "--format=%h%x1f%s%x1f%ct"], in: path)
        let branchesOutput = await run(git, [
            "for-each-ref", "refs/heads", "--sort=-committerdate", "--count=\(recentBranchCount)",
            "--format=%(refname:short)\u{1F}%(objectname:short)\u{1F}%(committerdate:unix)\u{1F}%(subject)",
        ], in: path)
        let worktreesOutput = await run(git, ["worktree", "list", "--porcelain"], in: path)
        let branchLogOutput = await runBranchLog(git, in: path)
        let diffOutput = GitStatusParser.parseStatus(statusOutput).hasTrackedChanges
            ? await runDiff(git, in: path)
            : nil
        return GitStatusParser.status(
            statusOutput: statusOutput,
            logOutput: logOutput,
            branchesOutput: branchesOutput,
            worktreesOutput: worktreesOutput,
            branchLogOutput: branchLogOutput,
            diffOutput: diffOutput
        )
    }

    /// The sixth read: the staged and unstaged changes of the tracked files
    /// against HEAD, with one line of context, in the whole repository
    /// (`:(top)`), without the files of `GitStatusParser.leftOutNames` and
    /// `leftOutFolders`. Each exclude has `top` too: without it, an exclude
    /// matches only under the project folder, and a lockfile at the root of
    /// the repository filled the byte limit. No
    /// color, no external diff and no textconv (both run programs that the
    /// repository's config names), and fixed `a/` and `b/` prefixes whatever
    /// `diff.noprefix` says. A repository with no commit has no HEAD, and
    /// the read is empty. The output is cut at `GitStatusParser.diffByteLimit`
    /// (`diffCommand`), so a large diff costs no time and no memory.
    static let diffArguments = [
        "diff", "HEAD", "--no-color", "--no-ext-diff", "--no-textconv", "-U1", "--src-prefix=a/", "--dst-prefix=b/", "--",
        ":(top)",
    ] + GitStatusParser.leftOutNames.map { ":(top,exclude,glob,icase)**/\($0)" }
        + GitStatusParser.leftOutFolders.map { ":(top,exclude,glob,icase)**/\($0)/**" }

    /// `diffArguments` after `git`, cut at `GitStatusParser.diffByteLimit`,
    /// as POSIX sh. A pathspec has no quote, `$`, backslash or backtick, so
    /// each goes in double quotes. git stops at the cut, because `head`
    /// closes the pipe.
    static func diffCommand(git: String) -> String {
        let arguments = diffArguments.map { $0.hasPrefix(":") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return "\(git) \(arguments) 2>/dev/null | head -c \(GitStatusParser.diffByteLimit)"
    }

    /// The refs that can be the main branch: the default branch of each
    /// remote (`origin/HEAD`, which the read resolves to the branch it
    /// names), and `main` or `master`, local or on a remote. A `*` here does
    /// not match a `/`.
    static let mainRefPatterns = [
        "refs/remotes/*/HEAD", "refs/heads/main", "refs/heads/master", "refs/remotes/*/main", "refs/remotes/*/master",
    ]

    /// The fifth read, as a POSIX sh script, the same for a local and a
    /// remote project. `git` is the command that runs git. It prints the
    /// main refs that exist, one on each line, then the commits of the
    /// current branch that none of them has (merges left out: a merge of
    /// the main branch into the branch is not its work), then `end`.
    /// Without a branch, a main ref or a successful log, there is no `end`,
    /// and `GitStatusParser.parseBranchLog` reads that as unknown: with no
    /// main ref, every commit of HEAD would read as the branch's own.
    /// A ref name has no space and no glob character (`git
    /// check-ref-format`), so `$m` splits into the refs.
    static func branchLogScript(git: String) -> String {
        let refFormat = "%(if)%(symref)%(then)%(symref)%(else)%(refname)%(end)"
        let patterns = mainRefPatterns.map { "\"\($0)\"" }.joined(separator: " ")
        return "b=$(\(git) symbolic-ref --short -q HEAD) && "
            + "m=$(\(git) for-each-ref \"--format=\(refFormat)\" \(patterns)) && [ -n \"$m\" ] && "
            + "printf \"%s\\n\" \"$m\" && "
            + "\(git) log -\(recentCommitCount) --no-merges --format=%h%x1f%s%x1f%ct \"refs/heads/$b\" --not $m -- && "
            + "echo end"
    }

    // MARK: - Remote

    /// What one remote read found.
    enum RemoteResult: Equatable {
        /// The host answered: its git state, or nil when the directory is
        /// not in a repository or the host has no git.
        case read(GitStatus?)
        /// No answer: no connection or no server is up, or the read timed
        /// out. What is known stays.
        case unreachable
    }

    /// The git state of a remote project's directory, from the host's
    /// server (`RemoteHosts.run`).
    static func remoteStatus(_ remote: ProjectPath) async -> RemoteResult {
        guard case let .remote(user, host, directory) = remote else { return .unreachable }
        let result = await RemoteHosts.shared.run(
            ["/bin/sh", "-c", RemoteSpawn.gitProbeScript(directory: directory)],
            destination: RemoteSpawn.destination(user: user, host: host),
            timeout: remoteTimeout
        )
        guard let result else { return .unreachable }
        return remoteResult(code: result.code, output: String(decoding: result.output.bytes, as: UTF8.self))
    }

    /// What the script's exit means. Pure.
    static func remoteResult(code: UInt8?, output: String) -> RemoteResult {
        switch code {
        case 0:
            .read(parseRemoteOutput(output))
        case 2,
             3,
             4:
            // The script's own exits: no such directory, no git, not a repository.
            .read(nil)
        default:
            .unreachable
        }
    }

    /// The six outputs of `RemoteSpawn.gitProbeScript`, split at the record
    /// separator, through `GitStatusParser`. A reply with fewer parts has
    /// the rest as nil. The diff is last, so a separator inside it stays
    /// part of it.
    static func parseRemoteOutput(_ output: String) -> GitStatus? {
        let parts = output.split(separator: recordSeparator, omittingEmptySubsequences: false).map(String.init)
        // An empty status is no repository, whatever the exit code was.
        guard let statusOutput = parts.first, !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return GitStatusParser.status(
            statusOutput: statusOutput,
            logOutput: parts.count > 1 ? parts[1] : nil,
            branchesOutput: parts.count > 2 ? parts[2] : nil,
            worktreesOutput: parts.count > 3 ? parts[3] : nil,
            branchLogOutput: parts.count > 4 ? parts[4] : nil,
            diffOutput: parts.count > 5 ? parts[5...].joined(separator: String(recordSeparator)) : nil
        )
    }

    // MARK: - Local git

    /// `executable()`, found once for each run of the app.
    static let resolvedExecutable: String? = executable()

    /// A git that runs without the install dialog, or nil.
    static func executable(fileManager: FileManager = .default) -> String? {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        guard let developerDirectory = developerDirectory() else { return nil }
        let git = (developerDirectory as NSString).appendingPathComponent("usr/bin/git")
        return fileManager.isExecutableFile(atPath: git) ? git : nil
    }

    /// `xcode-select -p`, which prints the developer directory and never
    /// opens a dialog. nil when none is selected.
    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The options of every git run. `core.quotePath=false` keeps a path
    /// with non-ASCII letters as it is, not C-quoted.
    static let gitOptions = ["-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "--no-pager"]

    /// stdout of `git -C path args`, or nil on a failure or a timeout.
    private static func run(_ git: String, _ args: [String], in path: String) async -> String? {
        await runChecked(git, ["-C", path] + gitOptions + args)
    }

    /// `branchLogScript` under `/bin/sh`. The git and the path go in as
    /// arguments, so neither is quoted into the script.
    private static func runBranchLog(_ git: String, in path: String) async -> String? {
        let command = (["\"$1\" -C \"$2\""] + gitOptions).joined(separator: " ")
        return await runChecked("/bin/sh", ["-c", branchLogScript(git: command), "sh", git, path])
    }

    /// `diffCommand` under `/bin/sh`, with the git and the path as arguments.
    private static func runDiff(_ git: String, in path: String) async -> String? {
        let command = (["\"$1\" -C \"$2\""] + gitOptions).joined(separator: " ")
        return await runChecked("/bin/sh", ["-c", diffCommand(git: command), "sh", git, path])
    }

    private static func runChecked(_ executable: String, _ args: [String]) async -> String? {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let outcome = await ProcessRunner.run(executable, args, environment: environment, timeout: timeout),
              outcome.status == 0
        else { return nil }
        return outcome.stdout
    }
}
