import Foundation
@testable import Macterm
import Testing

struct GitStatusParserTests {
    @Test
    func a_branch_with_upstream_and_changes() {
        let output = """
        # branch.oid 1234567890abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -4
        # stash 3
        1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
        1 M. N... 100644 100644 100644 aaa bbb README.md
        1 MM N... 100644 100644 100644 aaa bbb Package.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 New.swift\tOld.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc Conflict.swift
        ? notes.md
        ? scratch/
        """
        let status = GitStatusParser.parseStatus(output)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 4)
        #expect(status.stashes == 3)
        #expect(status.staged == 3)
        #expect(status.unstaged == 2)
        #expect(status.conflicted == 1)
        #expect(status.untracked == 2)
        #expect(status.changedFiles == 8)
        #expect(!status.isClean)
    }

    @Test
    func a_detached_head_keeps_its_short_commit() {
        let output = """
        # branch.oid abcdef1234567890
        # branch.head (detached)
        """
        let status = GitStatusParser.status(statusOutput: output, logOutput: nil)
        #expect(status.branch == nil)
        #expect(status.detachedAt == "abcdef1")
        #expect(status.isClean)
    }

    @Test
    func a_branch_with_no_upstream_and_no_commits() {
        let output = """
        # branch.oid (initial)
        # branch.head main
        ? first.txt
        """
        let status = GitStatusParser.status(statusOutput: output, logOutput: "")
        #expect(status.branch == "main")
        #expect(status.detachedAt == nil)
        #expect(status.upstream == nil)
        #expect(status.ahead == 0 && status.behind == 0)
        #expect(status.untracked == 1)
        #expect(status.recentCommits.isEmpty)
    }

    @Test
    func branches_come_with_the_worktree_that_has_them_checked_out() {
        let branches = "main\u{1F}abc1234\u{1F}1700000000\u{1F}Add the Makefile\nfeature/tax\u{1F}def5678\u{1F}1700003600\u{1F}Apply tax\n"
        let worktrees = """
        worktree /Users/me/dev/app
        HEAD abc1234abc1234
        branch refs/heads/main

        worktree /Users/me/dev/app-tax
        HEAD def5678def5678
        branch refs/heads/feature/tax

        worktree /Users/me/dev/app-old
        HEAD 0000000
        detached

        """
        let status = GitStatusParser.status(
            statusOutput: "# branch.head main\n", logOutput: nil, branchesOutput: branches, worktreesOutput: worktrees
        )
        #expect(status.branches.map(\.name) == ["main", "feature/tax"])
        #expect(status.branches[0].worktree == "/Users/me/dev/app")
        #expect(status.branches[1].worktree == "/Users/me/dev/app-tax")
        #expect(status.branches[1].subject == "Apply tax")
        #expect(status.branches[1].lastCommit == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(GitStatusParser.parseWorktrees(worktrees).count == 2)
    }

    @Test
    func the_log_is_hash_subject_and_time() {
        let log = "a1b2c3d\u{1F}Fix the thing\u{1F}1700000000\ne4f5a6b\u{1F}Add a feature\u{1F}1699990000\n"
        let commits = GitStatusParser.parseLog(log)
        #expect(commits.map(\.hash) == ["a1b2c3d", "e4f5a6b"])
        #expect(commits.first?.subject == "Fix the thing")
        #expect(commits.first?.date == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
