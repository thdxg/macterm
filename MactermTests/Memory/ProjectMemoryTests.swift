import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String?, exit: Int?, minutesAgo: Double = 0, directory: String? = "/repo") -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: directory,
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1
        )
    }

    // MARK: - Recording

    @Test
    func a_failure_keeps_a_redacted_tail_of_its_output() throws {
        let screen = """
        app % API_TOKEN=abc ./deploy
        connecting with API_TOKEN=abc
        error: rejected
        app %
        """
        let entry = try #require(ProjectMemory.makeEntry(
            screen: screen,
            source: ScreenCommandExtractor(),
            finish: .init(directory: "/app", exitCode: 1, finishedAt: now, duration: 3)
        ))
        #expect(entry.command == "API_TOKEN=••• ./deploy")
        #expect(entry.failureTail == "connecting with API_TOKEN=•••\nerror: rejected")
        #expect(entry.outcome == .failure)
        #expect(entry.startedAt == now.addingTimeInterval(-3))
    }

    @Test
    func a_success_keeps_no_output() throws {
        let screen = "app % make\nbuilt\napp %"
        let entry = try #require(ProjectMemory.makeEntry(
            screen: screen, source: ScreenCommandExtractor(), finish: .init(directory: nil, exitCode: 0, finishedAt: now, duration: 1)
        ))
        #expect(entry.command == "make")
        #expect(entry.failureTail == nil)
    }

    @Test
    func an_unreadable_screen_still_records_how_the_command_ended() throws {
        let entry = try #require(ProjectMemory.makeEntry(
            screen: nil, source: ScreenCommandExtractor(), finish: .init(directory: "/app", exitCode: nil, finishedAt: now, duration: 1)
        ))
        #expect(entry.command == nil)
        #expect(entry.outcome == .unknown)
    }

    @Test
    func a_private_command_is_not_recorded() {
        let screen = "app %  export TOKEN=abc\napp %"
        #expect(ProjectMemory.makeEntry(
            screen: screen, source: ScreenCommandExtractor(), finish: .init(directory: nil, exitCode: 0, finishedAt: now, duration: 1)
        ) == nil)
    }

    @Test
    func memory_covers_projects_only() {
        #expect(ProjectMemory.covers(UUID()))
        #expect(!ProjectMemory.covers(PinnedTabs.projectID))
        #expect(!ProjectMemory.covers(ScratchTabs.projectID))
        #expect(!ProjectMemory.covers(QuickTerminalService.projectID))
        #expect(!ProjectMemory.covers(DesktopWidget.projectID))
    }

    @Test
    func the_failure_tail_is_capped() throws {
        let output = (1 ... 50).map { "line \($0)" }.joined(separator: "\n")
        let tail = try #require(MemoryEntry.tail(of: output))
        let lines = tail.split(separator: "\n")
        #expect(lines.count == MemoryEntry.failureTailLines)
        #expect(lines.last == "line 50")
        #expect(MemoryEntry.tail(of: String(repeating: "x", count: 5000))?.utf8.count == MemoryEntry.failureTailBytes)
    }

    // MARK: - Summary

    @Test
    func a_failure_fixed_by_a_later_success_is_resolved() {
        let entries = [
            entry("make test", exit: 1, minutesAgo: 30),
            entry("make test", exit: 0, minutesAgo: 10),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure == nil)
    }

    @Test
    func the_latest_failure_with_no_later_success_is_unresolved() {
        let entries = [
            entry("make test", exit: 0, minutesAgo: 60),
            entry("npm run lint", exit: 1, minutesAgo: 30),
            entry("make test", exit: 2, minutesAgo: 10),
            entry("ls", exit: 0, minutesAgo: 5),
        ]
        let summary = ProjectMemorySummary(entries: entries)
        #expect(summary.unresolvedFailure?.command == "make test")
        #expect(summary.lastCommand?.command == "ls")
        #expect(summary.lastActivity == now.addingTimeInterval(-300))
        #expect(summary.commandCount == 4)
    }

    // MARK: - Quick actions

    @Test
    func the_unresolved_failure_comes_first_then_git_then_frecency() {
        let entries = [
            entry("npm run dev", exit: 0, minutesAgo: 900),
            entry("npm run dev", exit: 0, minutesAgo: 600),
            entry("npm run dev", exit: 0, minutesAgo: 300),
            entry("cargo build", exit: 0, minutesAgo: 20),
            entry("ls -la", exit: 0, minutesAgo: 2),
            entry("make test", exit: 1, minutesAgo: 1),
        ]
        var git = GitStatus(branch: "main", upstream: "origin/main")
        git.behind = 3
        git.unstaged = 2
        let actions = QuickActionRanker.actions(entries: entries, git: git, now: now)

        #expect(actions.map(\.kind) == [.retry, .git, .git, .frequent, .frequent])
        #expect(actions[0].command == "make test")
        #expect(actions[1].command == "git pull")
        #expect(actions[2].command == "git status")
        // Three runs within a day outweigh one run in the last hour.
        #expect(actions[3].command == "npm run dev")
        #expect(actions[4].command == "cargo build")
        // Moving around is not worth a button.
        #expect(!actions.contains { $0.command == "ls -la" })
    }

    @Test
    func two_spellings_of_one_command_rank_as_one() {
        let entries = [
            entry("swift  build", exit: 0, minutesAgo: 5),
            entry("swift build", exit: 0, minutesAgo: 1),
        ]
        let actions = QuickActionRanker.actions(entries: entries, git: nil, now: now)
        #expect(actions.map(\.command) == ["swift build"])
    }

    @Test
    func there_are_at_most_six_actions() {
        let entries = (0 ..< 20).map { entry("task \($0)", exit: 0, minutesAgo: Double($0)) }
        #expect(QuickActionRanker.actions(entries: entries, git: nil, now: now).count == QuickActionRanker.limit)
    }

    @Test
    func a_clean_branch_in_step_with_its_upstream_adds_no_git_action() {
        let git = GitStatus(branch: "main", upstream: "origin/main")
        #expect(QuickActionRanker.actions(entries: [], git: git, now: now).isEmpty)
    }
}
