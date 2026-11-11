@testable import Macterm
import Testing

struct ProjectMemorySummaryTests {
    @Test
    func the_nothing_to_summarize_line_shows_only_for_a_project_with_neither_commands_nor_git_state() {
        #expect(ProjectMemorySummary.showsNothingToSummarize(hasCommands: false, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsNothingToSummarize(hasCommands: false, hasGitStateOrUnknown: true))
        #expect(!ProjectMemorySummary.showsNothingToSummarize(hasCommands: true, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsNothingToSummarize(hasCommands: true, hasGitStateOrUnknown: true))
    }
}
