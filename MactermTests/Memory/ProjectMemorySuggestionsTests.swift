import Foundation
@testable import Macterm
import Testing

struct ProjectMemorySuggestionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String?, exit: Int = 0, minutesAgo: Double, directory: String? = "/repo") -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: directory,
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1
        )
    }

    private func suggestion(_ command: String, _ reason: String = "because") -> OnDeviceModel.Suggestion {
        OnDeviceModel.Suggestion(command: command, reason: reason)
    }

    @Test
    func candidates_are_the_projects_own_commands_newest_first_with_no_noise() {
        let entries = [
            entry("make build", minutesAgo: 30),
            entry("ls", minutesAgo: 20),
            entry("export TOKEN=•••", minutesAgo: 15),
            entry("make  test", minutesAgo: 10),
            entry(nil, minutesAgo: 5),
            entry("make build", minutesAgo: 1),
        ]
        #expect(ProjectMemorySuggestions.candidates(entries: entries) == ["make build", "make test"])
    }

    @Test
    func only_known_commands_are_kept_in_the_models_order() {
        let entries = [entry("make build", minutesAgo: 30, directory: "/repo/app"), entry("make test", exit: 1, minutesAgo: 1)]
        let actions = ProjectMemorySuggestions.actions(from: [
            suggestion("make test", "The latest run failed."),
            suggestion("rm -rf /", "Clean up."),
            suggestion("git status", "See the changed files."),
            suggestion("make build"),
            suggestion("make test", "Again."),
        ], entries: entries)

        #expect(actions.map(\.command) == ["make test", "git status", "make build"])
        #expect(actions.allSatisfy { $0.kind == .suggested })
        #expect(actions[0].subtitle == "The latest run failed.")
        #expect(actions[0].symbol == "xmark.circle")
        #expect(actions[2].directory == "/repo/app")
    }

    @Test
    func a_masked_or_trivial_command_is_never_suggested() {
        let entries = [entry("curl -u me:••• https://x", minutesAgo: 2), entry("ls", minutesAgo: 1)]
        let actions = ProjectMemorySuggestions.actions(from: [suggestion("curl -u me:••• https://x"), suggestion("ls")], entries: entries)
        #expect(actions.isEmpty)
    }

    @Test
    func there_are_at_most_five_suggestions() {
        let entries = (0 ..< 10).map { entry("task \($0)", minutesAgo: Double($0)) }
        let actions = ProjectMemorySuggestions.actions(from: (0 ..< 10).map { suggestion("task \($0)") }, entries: entries)
        #expect(actions.count == ProjectMemorySuggestions.limit)
    }
}
