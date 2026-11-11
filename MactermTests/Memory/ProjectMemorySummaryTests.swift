@testable import Macterm
import Testing

struct ProjectMemorySummaryTests {
    @Test
    func the_git_only_note_shows_only_for_a_project_with_neither_commands_nor_git_state() {
        #expect(ProjectMemorySummary.showsGitOnlyNote(hasCommands: false, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsGitOnlyNote(hasCommands: false, hasGitStateOrUnknown: true))
        #expect(!ProjectMemorySummary.showsGitOnlyNote(hasCommands: true, hasGitStateOrUnknown: false))
        #expect(!ProjectMemorySummary.showsGitOnlyNote(hasCommands: true, hasGitStateOrUnknown: true))
    }
}
