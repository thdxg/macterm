@testable import Macterm
import Testing

struct ProjectMemorySummaryTests {
    @Test
    func the_no_commands_line_shows_only_for_a_project_with_neither_commands_nor_git_state() {
        #expect(ProjectMemorySummary.showsNoCommandsLine(hasCommands: false, hasGitState: false))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: false, hasGitState: true))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: true, hasGitState: false))
        #expect(!ProjectMemorySummary.showsNoCommandsLine(hasCommands: true, hasGitState: true))
    }
}
