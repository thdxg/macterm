import Foundation
@testable import Macterm
import Testing

struct ProjectMemoryAnswerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String?, exit: Int?, minutesAgo: Double) -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: "/repo",
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1
        )
    }

    private func answer(_ entries: [MemoryEntry], summary: StoredSummary? = nil) -> String {
        ProjectMemoryAnswer.text(projectName: "acme", entries: entries, summary: summary, now: now)
    }

    @Test
    func an_empty_log_says_so() {
        #expect(answer([]) == "Nothing has run in acme yet.")
    }

    @Test
    func without_a_summary_the_last_command_and_its_result_answer() {
        #expect(answer([entry("make build", exit: 0, minutesAgo: 5)]) == "The last command, make build, succeeded 5 minutes ago.")
        #expect(answer([entry("make test", exit: 2, minutesAgo: 120)]) ==
            "The last command, make test, failed with exit code 2 2 hours ago.")
        #expect(answer([entry("make test", exit: nil, minutesAgo: 0)]) == "The last command, make test, ended now.")
    }

    @Test
    func a_failure_that_did_not_succeed_since_is_named_after_the_last_command() {
        let entries = [entry("make test", exit: 1, minutesAgo: 30), entry("git status", exit: 0, minutesAgo: 1)]
        #expect(answer(entries) ==
            "The last command, git status, succeeded 1 minute ago. make test failed with exit code 1 and has not succeeded since.")

        // A failure that is the last command is said one time.
        #expect(answer([entry("make test", exit: 1, minutesAgo: 30)]) ==
            "The last command, make test, failed with exit code 1 30 minutes ago.")
    }

    @Test
    func a_failure_that_a_retry_fixed_is_not_named() {
        let entries = [
            entry("git clean", exit: 128, minutesAgo: 30),
            entry("git clean -f", exit: 0, minutesAgo: 29),
            entry("git status", exit: 0, minutesAgo: 1),
        ]
        #expect(answer(entries) == "The last command, git status, succeeded 1 minute ago.")
    }

    @Test
    func a_log_with_no_command_text_counts_the_commands() {
        #expect(answer([entry(nil, exit: 0, minutesAgo: 60), entry(nil, exit: 0, minutesAgo: 10)]) ==
            "2 commands ran in acme, the last one 10 minutes ago.")
    }

    @Test
    func the_stored_summary_answers_with_no_backticks_and_the_commands_since_it() {
        let written = now.addingTimeInterval(-20 * 60)
        let summary = StoredSummary(key: "k", text: "You were fixing `make test`.", writtenAt: written)
        let before = [entry("make test", exit: 1, minutesAgo: 30)]
        #expect(answer(before, summary: summary) == "You were fixing make test.")

        let since = before + [entry("make test", exit: 0, minutesAgo: 5)]
        #expect(answer(since, summary: summary) == "You were fixing make test. The last command, make test, succeeded 5 minutes ago.")

        // An empty summary is no summary.
        let empty = StoredSummary(key: "k", text: "", writtenAt: written)
        #expect(answer(before, summary: empty) == "The last command, make test, failed with exit code 1 30 minutes ago.")
    }
}
