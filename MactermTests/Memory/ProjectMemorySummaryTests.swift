@testable import Macterm
import Testing

struct ProjectMemorySummaryTests {
    @Test
    func the_no_commands_line_shows_only_for_a_project_with_neither_commands_nor_git_state() {
        #expect(ProjectMemorySummary.showsNoCommandsLine(hasCommands: false, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: false, hasGitStateOrUnknown: true))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: true, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: true, hasGitStateOrUnknown: true))
    }
}
