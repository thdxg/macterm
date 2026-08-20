import Foundation
@testable import Macterm
import Testing

/// The sidebar shows this string verbatim, so what it refuses to show matters
/// as much as what it does.
@MainActor
struct GitBranchNamesTests {
    @Test
    func a_branch_name_is_trimmed_of_the_trailing_newline() {
        #expect(GitBranchNames.parseBranch("feat/git-panel\n") == "feat/git-panel")
    }

    /// `git rev-parse --abbrev-ref HEAD` answers the literal string `HEAD` on a
    /// detached HEAD. Showing that as a branch would be a lie the sidebar
    /// repeats on every row of a bisect.
    @Test
    func a_detached_head_is_not_a_branch() {
        #expect(GitBranchNames.parseBranch("HEAD\n") == nil)
    }

    @Test
    func empty_output_is_no_branch() {
        #expect(GitBranchNames.parseBranch("") == nil)
        #expect(GitBranchNames.parseBranch("\n") == nil)
    }

    @Test
    func slashes_and_unicode_survive() {
        #expect(GitBranchNames.parseBranch("feature/año-nuevo\n") == "feature/año-nuevo")
    }

    @Test
    func an_unread_directory_has_no_branch() {
        let names = GitBranchNames()
        #expect(names.branch(for: "/tmp/never-read") == nil)
    }

    /// An empty directory is what a remote project (or a pane with no readable
    /// cwd) resolves to, and it must not spawn a subprocess against the
    /// process's own working directory — which would report Macterm's branch.
    @Test
    func an_empty_directory_is_never_read() {
        let names = GitBranchNames()
        names.refresh(directory: "")
        #expect(names.branch(for: "") == nil)
    }
}
