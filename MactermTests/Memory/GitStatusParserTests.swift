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
        #expect(status.changedPaths == [
            "Sources/App.swift", "README.md", "Package.swift", "New.swift", "Conflict.swift", "notes.md", "scratch/",
        ])
    }

    @Test
    func a_path_with_spaces_is_kept_whole() {
        let output = "1 .M N... 100644 100644 100644 aaa bbb Docs/Read Me.md\n? My Notes.txt\n"
        #expect(GitStatusParser.parseStatus(output).changedPaths == ["Docs/Read Me.md", "My Notes.txt"])
    }

    @Test
    func the_branch_log_has_the_main_refs_and_the_commits_of_the_branch() throws {
        let log = "refs/heads/main\nrefs/remotes/origin/main\nrefs/remotes/origin/main\na1b2c3d\u{1F}Apply tax\u{1F}1700000000\nend\n"
        let status = GitStatusParser.status(statusOutput: "# branch.head feature/tax\n", logOutput: nil, branchLogOutput: log)
        #expect(status.mainRefs == ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(status.branchCommits?.map(\.subject) == ["Apply tax"])
        #expect(!status.isOnMainBranch)
        let none = try #require(GitStatusParser.parseBranchLog("refs/heads/main\nend\n"))
        #expect(none.commits.isEmpty)
    }

    @Test
    func a_branch_log_that_did_not_finish_or_found_no_main_branch_is_unknown() {
        #expect(GitStatusParser.parseBranchLog("refs/heads/main\na1b2c3d\u{1F}Apply tax\u{1F}1700000000\n") == nil)
        #expect(GitStatusParser.parseBranchLog("a1b2c3d\u{1F}Apply tax\u{1F}1700000000\nend\n") == nil)
        #expect(GitStatusParser.parseBranchLog("") == nil)
        let detached = GitStatusParser.status(
            statusOutput: "# branch.oid abcdef1234567890\n# branch.head (detached)\n",
            logOutput: nil,
            branchLogOutput: "refs/heads/main\nend\n"
        )
        #expect(detached.branchCommits == nil)
    }

    @Test
    func the_branch_that_a_remote_head_names_is_a_main_branch() {
        var status = GitStatus(branch: "develop")
        status.mainRefs = ["refs/remotes/origin/develop"]
        #expect(status.isOnMainBranch)
        status.mainRefs = ["refs/heads/main", "refs/remotes/origin/main"]
        #expect(!status.isOnMainBranch)
        status.branch = "main"
        #expect(status.isOnMainBranch)
        status.branch = "team/main"
        #expect(!status.isOnMainBranch)
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

    // MARK: - Diff

    private let changedStatus = "# branch.head main\n1 .M N... 100644 100644 100644 aaa bbb app.swift\n"

    @Test
    func a_diff_keeps_the_hunks_of_each_file() {
        let diff = """
        diff --git a/app.swift b/app.swift
        index 1111111..2222222 100644
        --- a/app.swift
        +++ b/app.swift
        @@ -1,2 +1,2 @@ func total()
         let a = 1
        -let rate = 0.1
        +let rate = 0.2
        diff --git a/My Notes.md b/My Notes.md
        new file mode 100644
        --- /dev/null
        +++ b/My Notes.md\t
        @@ -0,0 +1 @@
        +hello
        diff --git a/old.swift b/old.swift
        deleted file mode 100644
        --- a/old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone

        """
        let files = GitStatusParser.parseDiff(diff)
        #expect(files.map(\.path) == ["app.swift", "My Notes.md", "old.swift"])
        #expect(files[0].lines == ["@@ -1,2 +1,2 @@ func total()", " let a = 1", "-let rate = 0.1", "+let rate = 0.2"])
        #expect(files[2].lines == [GitStatusParser.deletedFileLine])
    }

    @Test
    func a_secret_in_a_hunk_is_masked_and_secret_files_are_left_out() {
        let diff = """
        diff --git a/config.yml b/config.yml
        --- a/config.yml
        +++ b/config.yml
        @@ -1 +1,3 @@
        +db_password: hunter2
        +API_TOKEN=abc123
        +"client_secret": "s3cr3t",
        diff --git a/.env.local b/.env.local
        --- a/.env.local
        +++ b/.env.local
        @@ -1 +1 @@
        +STRIPE=sk_live_plain
        diff --git a/web/package-lock.json b/web/package-lock.json
        --- a/web/package-lock.json
        +++ b/web/package-lock.json
        @@ -1 +1 @@
        +"lockfileVersion": 3
        diff --git a/deploy/key b/deploy/key
        --- a/deploy/key
        +++ b/deploy/key
        @@ -0,0 +1,3 @@
        +-----BEGIN OPENSSH PRIVATE KEY-----
        +b3BlbnNzaC1rZXktdjEAAAAA
        +-----END OPENSSH PRIVATE KEY-----
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let files = GitStatusParser.parseDiff(diff)
        #expect(files.map(\.path) == ["config.yml"])
        let text = files[0].lines.joined(separator: "\n")
        for secret in ["hunter2", "abc123", "s3cr3t"] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains("db_password: \(MemoryRedaction.mask)"))
    }

    @Test
    func a_clean_tree_reads_no_diff() {
        let diff = "diff --git a/app.swift b/app.swift\n--- a/app.swift\n+++ b/app.swift\n@@ -1 +1 @@\n+x\n"
        // Untracked files alone have no diff to read.
        for statusOutput in ["# branch.head main\n", "# branch.head main\n? notes.md\n"] {
            #expect(GitStatusParser.status(statusOutput: statusOutput, logOutput: nil, diffOutput: diff).diff == nil)
        }
        #expect(GitStatusParser.status(statusOutput: changedStatus, logOutput: nil, diffOutput: diff).diff?.count == 1)
    }

    @Test
    func a_diff_past_the_limit_leaves_out_whole_files() {
        let big = String(repeating: "x", count: GitStatusParser.diffCharacterLimit)
        let diff = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1 +1 @@\n+\(big)\n"
            + "diff --git a/small.txt b/small.txt\n--- a/small.txt\n+++ b/small.txt\n@@ -1 +1 @@\n+small\n"
        #expect(GitStatusParser.parseDiff(diff).map(\.path) == ["small.txt"])
    }
}
