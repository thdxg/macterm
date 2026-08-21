import Foundation
@testable import Macterm
import Testing

/// Pins the shapes of git's machine-readable output that a naive line-based
/// reader gets wrong: NUL framing, renames spending extra fields, and the two
/// status columns meaning different things.
@MainActor
struct GitStatusTests {
    // MARK: - status --porcelain=v1 -z

    @Test
    func parses_the_two_status_columns_separately() throws {
        // "MM" is staged AND dirty — the case a single-state row would lie
        // about, since a commit now captures only the staged half.
        let changes = GitStatusParser.parse(porcelain: "MM src/a.swift\0")
        let change = try #require(changes.first)
        #expect(change.path == "src/a.swift")
        #expect(change.index == .modified)
        #expect(change.worktree == .modified)
        #expect(change.isStaged)
    }

    @Test
    func a_clean_column_is_nil_not_a_state() throws {
        let changes = GitStatusParser.parse(porcelain: " M src/a.swift\0")
        let change = try #require(changes.first)
        #expect(change.index == nil)
        #expect(change.worktree == .modified)
        #expect(!change.isStaged)
    }

    @Test
    func untracked_and_ignored_have_their_own_states() {
        let changes = GitStatusParser.parse(porcelain: "?? new.txt\0!! build/\0")
        #expect(changes.count == 2)
        #expect(changes[0].worktree == .untracked)
        #expect(changes[1].worktree == .ignored)
    }

    /// A rename's origin arrives as its OWN NUL field. Consuming one field per
    /// entry would read that origin as the next entry and shift every row
    /// after it.
    @Test
    func a_rename_consumes_its_origin_field() {
        let changes = GitStatusParser.parse(porcelain: "R  new.swift\0old.swift\0 M other.swift\0")
        #expect(changes.count == 2)
        #expect(changes[0].path == "new.swift")
        #expect(changes[0].index == .renamed(from: "old.swift"))
        #expect(changes[1].path == "other.swift")
        #expect(changes[1].worktree == .modified)
    }

    @Test
    func conflicts_are_not_read_as_staged_plus_dirty() throws {
        for porcelain in ["UU a.swift\0", "AA a.swift\0", "DD a.swift\0"] {
            let change = try #require(GitStatusParser.parse(porcelain: porcelain).first)
            #expect(change.isConflicted)
        }
    }

    @Test
    func paths_with_spaces_survive_nul_framing() throws {
        let change = try #require(GitStatusParser.parse(porcelain: " M src/my file.swift\0").first)
        #expect(change.path == "src/my file.swift")
    }

    // MARK: - diff --numstat -z

    @Test
    func numstat_reads_counts_and_path_from_one_field() {
        let counts = GitStatusParser.parseNumstat("12\t3\tsrc/a.swift\0")
        #expect(counts["src/a.swift"]?.additions == 12)
        #expect(counts["src/a.swift"]?.deletions == 3)
    }

    /// A rename leaves the third component empty and spends two more fields:
    /// old path, then new. The counts belong to the NEW path, which is what
    /// the status rows are keyed on.
    @Test
    func numstat_keys_a_rename_on_its_new_path() {
        let counts = GitStatusParser.parseNumstat("4\t2\t\0old.swift\0new.swift\0")
        #expect(counts["new.swift"]?.additions == 4)
        #expect(counts["old.swift"] == nil)
    }

    @Test
    func numstat_reads_a_binary_files_dashes_as_zero() {
        let counts = GitStatusParser.parseNumstat("-\t-\tassets/icon.png\0")
        #expect(counts["assets/icon.png"]?.additions == 0)
        #expect(counts["assets/icon.png"]?.deletions == 0)
    }

    @Test
    func numstat_reads_several_entries() {
        let counts = GitStatusParser.parseNumstat("1\t0\ta.swift\0 2\t2\tb.swift\0".replacingOccurrences(of: "\0 ", with: "\0"))
        #expect(counts.count == 2)
        #expect(counts["b.swift"]?.deletions == 2)
    }

    // MARK: - diff classification

    /// `+++`/`---` open the same way as added and deleted lines. Testing them
    /// before the +/- rule is the whole reason the classifier isn't a two-line
    /// `hasPrefix` check.
    @Test
    func file_headers_are_not_read_as_changed_lines() {
        let lines = GitDiffParser.lines("--- a/x.swift\n+++ b/x.swift\n")
        #expect(lines[0].kind == .meta)
        #expect(lines[1].kind == .meta)
    }

    @Test
    func classifies_hunks_additions_deletions_and_context() {
        let lines = GitDiffParser.lines("@@ -1,3 +1,4 @@\n context\n+added\n-removed\n")
        #expect(lines[0].kind == .hunk)
        #expect(lines[1].kind == .context)
        #expect(lines[2].kind == .addition)
        #expect(lines[3].kind == .deletion)
    }

    @Test
    func file_name_and_directory_split_the_path() {
        let change = GitFileChange(path: "Macterm/Views/Sidebar.swift", index: nil, worktree: .modified)
        #expect(change.fileName == "Sidebar.swift")
        #expect(change.directory == "Macterm/Views")
    }

    @Test
    func a_root_level_file_has_no_directory() {
        let change = GitFileChange(path: "README.md", index: nil, worktree: .modified)
        #expect(change.fileName == "README.md")
        #expect(change.directory.isEmpty)
    }
}
