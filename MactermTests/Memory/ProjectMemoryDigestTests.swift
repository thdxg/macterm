import Foundation
@testable import Macterm
import Testing

struct ProjectMemoryDigestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String, exit: Int?, minutesAgo: Double, tail: String? = nil) -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: "/repo",
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1,
            failureTail: tail
        )
    }

    @Test
    func the_digest_lists_the_git_state_and_the_commands_newest_first() throws {
        var git = GitStatus(branch: "main", upstream: "origin/main")
        git.behind = 3
        git.unstaged = 2
        git.recentCommits = [GitStatus.Commit(hash: "abc1234", subject: "Add checkout", date: now)]
        let entries = [
            entry("make build", exit: 0, minutesAgo: 30),
            entry("make test", exit: 2, minutesAgo: 2, tail: "FAIL checkout totals\n17 passed, 1 failed"),
        ]
        let digest = try #require(ProjectMemoryDigest(projectName: "acme-site", entries: entries, git: git, now: now))
        let lines = digest.text.split(separator: "\n").map(String.init)

        #expect(lines[0] == "Git: branch main; 3 commits behind origin/main; uncommitted changes: 2 modified")
        #expect(lines[1] == "Latest commits: \"Add checkout\"")
        #expect(lines[2] == "Commands, newest first:")
        #expect(lines[3] == "- 2 minutes ago: `make test` failed with exit code 2 in /repo")
        #expect(lines[4] == "  output:")
        #expect(lines[5] == "    FAIL checkout totals")
        #expect(lines[7] == "- 30 minutes ago: `make build` succeeded in /repo")
        #expect(digest.prompt.hasPrefix("Project: acme-site\n<<<\n"))
        #expect(digest.prompt.hasSuffix("\n>>>"))
    }

    @Test
    func other_branches_are_in_the_digest_and_its_key() throws {
        var git = GitStatus(branch: "main")
        git.branches = [
            GitStatus.Branch(name: "main", hash: "a1", subject: "Add the Makefile", lastCommit: now.addingTimeInterval(-86400)),
            GitStatus.Branch(
                name: "feature/tax",
                hash: "b2",
                subject: "Apply tax",
                lastCommit: now.addingTimeInterval(-7200),
                worktree: "/w/app-tax"
            ),
        ]
        let digest = try #require(ProjectMemoryDigest(projectName: "x", entries: [], git: git, now: now))
        #expect(digest.text.contains(
            "Other branches with recent commits: `feature/tax` (2 hours ago: \"Apply tax\", checked out in the worktree /w/app-tax)"
        ))
        #expect(!digest.text.contains("`main` ("))
        var moved = git
        moved.branches[1].hash = "c3"
        #expect(ProjectMemoryDigest(projectName: "x", entries: [], git: moved, now: now)?.key != digest.key)
    }

    @Test
    func the_suggestion_prompt_lists_the_candidates_and_the_allowed_git_commands() throws {
        let entries = [entry("make build", exit: 0, minutesAgo: 5), entry("make test", exit: 2, minutesAgo: 1)]
        let digest = try #require(ProjectMemoryDigest(projectName: "x", entries: entries, git: nil, now: now))
        #expect(digest.candidates == ["make test", "make build"])
        let lines = digest.suggestionPrompt.split(separator: "\n").map(String.init)
        #expect(lines[1] == "Commands that ran in this project, newest first:")
        #expect(lines[2] == "- make test")
        #expect(lines[3] == "- make build")
        #expect(lines[4].hasPrefix("Allowed git commands: git status, git pull"))
    }

    @Test
    func the_reply_language_goes_in_the_prompt() throws {
        let digest = try #require(ProjectMemoryDigest(
            projectName: "x", entries: [entry("ls", exit: 0, minutesAgo: 1)], git: nil, now: now, replyLanguage: "Korean"
        ))
        #expect(digest.prompt.contains("Write the reply in Korean."))
    }

    @Test
    func an_empty_log_with_no_git_state_has_nothing_to_say() {
        #expect(ProjectMemoryDigest(projectName: "x", entries: [], git: nil, now: now) == nil)
        #expect(ProjectMemoryDigest(projectName: "x", entries: [], git: GitStatus(branch: "main"), now: now) != nil)
    }

    @Test
    func only_the_latest_commands_are_in_the_digest() throws {
        let entries = (0 ..< 30).map { entry("task \($0)", exit: 0, minutesAgo: Double(30 - $0)) }
        let digest = try #require(ProjectMemoryDigest(projectName: "x", entries: entries, git: nil, now: now))
        #expect(digest.text.contains("`task 29`"))
        #expect(digest.text.contains("`task 18`"))
        #expect(!digest.text.contains("`task 17`"))
    }

    @Test
    func a_long_digest_is_cut_to_the_budget() throws {
        let tail = String(repeating: "error line that goes on and on\n", count: 200)
        let entries = (0 ..< 12).map { entry("cmd \($0)", exit: 1, minutesAgo: Double($0), tail: tail) }
        let digest = try #require(ProjectMemoryDigest(projectName: "x", entries: entries, git: nil, now: now))
        #expect(OutputExplanation.estimatedTokens(digest.text) <= ProjectMemoryDigest.textTokenBudget + 50)
    }

    @Test
    func the_key_does_not_change_as_time_passes() throws {
        let entries = [entry("make build", exit: 0, minutesAgo: 1), entry("make test", exit: 2, minutesAgo: 0)]
        let git = GitStatus(branch: "main")
        let first = try #require(ProjectMemoryDigest(projectName: "x", entries: entries, git: git, now: now))
        let later = try #require(ProjectMemoryDigest(projectName: "x", entries: entries, git: git, now: now.addingTimeInterval(3600)))
        #expect(first.key == later.key)
        #expect(first.text != later.text)

        var changed = entries
        changed[1].exitCode = 0
        #expect(ProjectMemoryDigest(projectName: "x", entries: changed, git: git, now: now)?.key != first.key)
        var dirty = git
        dirty.unstaged = 1
        #expect(ProjectMemoryDigest(projectName: "x", entries: entries, git: dirty, now: now)?.key != first.key)
    }

    @Test
    func ages_read_as_english_for_the_model() {
        #expect(ProjectMemoryDigest.age(of: now, now: now) == "just now")
        #expect(ProjectMemoryDigest.age(of: now.addingTimeInterval(-90), now: now) == "1 minute ago")
        #expect(ProjectMemoryDigest.age(of: now.addingTimeInterval(-7200), now: now) == "2 hours ago")
        #expect(ProjectMemoryDigest.age(of: now.addingTimeInterval(-3 * 86400), now: now) == "3 days ago")
    }

    @Test
    func a_detached_head_and_a_clean_tree_read_right() {
        var git = GitStatus()
        git.detachedAt = "abc1234"
        git.stashes = 1
        #expect(ProjectMemoryDigest.gitLine(git) == "detached at abc1234; no uncommitted changes; 1 stashes")
    }
}
