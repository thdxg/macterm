import Foundation
@testable import Macterm
import Testing

struct ProjectGitTests {
    private let status = """
    # branch.oid 1234567890abcdef
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +1 -2
    1 .M N... 100644 100644 100644 abc def Sources/App.swift
    """

    @Test
    func a_remote_reply_splits_into_the_five_outputs() throws {
        let reply = [
            status,
            "abc1234\u{1F}Fix the build\u{1F}1800000000\n",
            "main\u{1F}abc1234\u{1F}1800000000\u{1F}Fix the build\n"
                + "feature/tax\u{1F}def5678\u{1F}1799990000\u{1F}Add tax\n",
            "worktree /work/app\nHEAD 1234567890abcdef\nbranch refs/heads/main\n\n"
                + "worktree /work/tax\nHEAD def5678\nbranch refs/heads/feature/tax\n\n",
            "refs/remotes/origin/main\nabc1234\u{1F}Fix the build\u{1F}1800000000\nend\n",
        ].joined(separator: String(ProjectGit.recordSeparator))
        let git = try #require(ProjectGit.parseRemoteOutput(reply))
        #expect(git.branch == "main")
        #expect(git.ahead == 1)
        #expect(git.behind == 2)
        #expect(git.unstaged == 1)
        #expect(git.recentCommits.map(\.subject) == ["Fix the build"])
        #expect(git.branches.map(\.name) == ["main", "feature/tax"])
        #expect(git.branches.last?.worktree == "/work/tax")
        #expect(git.branchCommits?.map(\.hash) == ["abc1234"])
    }

    @Test
    func the_branch_log_leaves_out_the_main_refs_that_exist_and_merges() {
        let script = ProjectGit.branchLogScript(git: "git")
        #expect(script.hasPrefix("b=$(git symbolic-ref --short -q HEAD) && "))
        #expect(script.contains(
            "for-each-ref \"--format=%(if)%(symref)%(then)%(symref)%(else)%(refname)%(end)\" \"refs/remotes/*/HEAD\" "
                + "\"refs/heads/main\" \"refs/heads/master\" \"refs/remotes/*/main\" \"refs/remotes/*/master\") && [ -n \"$m\" ]"
        ))
        #expect(script.contains("log -5 --no-merges --format=%h%x1f%s%x1f%ct \"refs/heads/$b\" --not $m -- && echo end"))
        #expect(!script.contains("'"))
    }

    @Test
    func git_runs_with_unquoted_paths() {
        #expect(ProjectGit.gitOptions.contains("core.quotePath=false"))
    }

    @Test
    func a_reply_with_the_status_alone_still_reads() throws {
        let git = try #require(ProjectGit.parseRemoteOutput(status))
        #expect(git.branch == "main")
        #expect(git.recentCommits.isEmpty)
        #expect(git.branches.isEmpty)
        #expect(git.branchCommits == nil)
    }

    @Test
    func an_empty_reply_is_no_state() {
        #expect(ProjectGit.parseRemoteOutput("") == nil)
    }
}
