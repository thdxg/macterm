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
    func a_remote_reply_splits_into_the_four_outputs() throws {
        let reply = [
            status,
            "abc1234\u{1F}Fix the build\u{1F}1800000000\n",
            "main\u{1F}abc1234\u{1F}1800000000\u{1F}Fix the build\n"
                + "feature/tax\u{1F}def5678\u{1F}1799990000\u{1F}Add tax\n",
            "worktree /work/app\nHEAD 1234567890abcdef\nbranch refs/heads/main\n\n"
                + "worktree /work/tax\nHEAD def5678\nbranch refs/heads/feature/tax\n\n",
        ].joined(separator: String(ProjectGit.recordSeparator))
        let git = try #require(ProjectGit.parseRemoteOutput(reply))
        #expect(git.branch == "main")
        #expect(git.ahead == 1)
        #expect(git.behind == 2)
        #expect(git.unstaged == 1)
        #expect(git.recentCommits.map(\.subject) == ["Fix the build"])
        #expect(git.branches.map(\.name) == ["main", "feature/tax"])
        #expect(git.branches.last?.worktree == "/work/tax")
    }

    @Test
    func a_reply_with_the_status_alone_still_reads() throws {
        let git = try #require(ProjectGit.parseRemoteOutput(status))
        #expect(git.branch == "main")
        #expect(git.recentCommits.isEmpty)
        #expect(git.branches.isEmpty)
    }

    @Test
    func an_empty_reply_is_no_state() {
        #expect(ProjectGit.parseRemoteOutput("") == nil)
    }
}
