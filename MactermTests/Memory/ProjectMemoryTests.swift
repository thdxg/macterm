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
    func the_reported_command_wins_and_the_screen_gives_only_a_matching_tail() throws {
        let screen = """
        app % make test
        FAIL checkout
        app %
        """
        let finish = ProjectMemory.Finish(directory: "/app", exitCode: 1, finishedAt: now, duration: 3)
        let reported = try #require(ProjectMemory.reportedCommand("make test  "))
        #expect(reported == ExtractedCommand(command: "make test", output: ""))

        // The screen shows the same command: its tail is kept.
        let entry = try #require(ProjectMemory.makeEntry(
            reported: reported, submitted: ExtractedCommand(command: "make", output: ""),
            screen: screen, source: ScreenCommandExtractor(), finish: finish
        ))
        #expect(entry.command == "make test")
        #expect(entry.failureTail == "FAIL checkout")

        // Another command on the screen: the reported one stays, with no tail.
        let other = try #require(ProjectMemory.makeEntry(
            reported: ProjectMemory.reportedCommand("make lint"), screen: screen, source: ScreenCommandExtractor(), finish: finish
        ))
        #expect(other.command == "make lint")
        #expect(other.failureTail == nil)

        // A leading space is private, and text with no command is nothing.
        #expect(ProjectMemory.reportedCommand(" secret")?.isPrivate == true)
        #expect(ProjectMemory.makeEntry(
            reported: ProjectMemory.reportedCommand(" secret"), screen: screen, source: ScreenCommandExtractor(), finish: finish
        ) == nil)
        #expect(ProjectMemory.reportedCommand("   ") == nil)
    }

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
    func a_command_that_nothing_names_is_not_recorded() {
        #expect(ProjectMemory.makeEntry(
            screen: "app %", source: ScreenCommandExtractor(), finish: .init(directory: "/app", exitCode: 0, finishedAt: now, duration: 1)
        ) == nil)
    }

    @Test
    func clear_is_recorded_from_the_line_captured_at_submission() throws {
        // `clear` wipes the screen, so after it only the new prompt is left.
        let submitted = try #require(ScreenCommandExtractor.typedCommand(onScreen: "~/app on main\n❯ clear"))
        let entry = try #require(ProjectMemory.makeEntry(
            submitted: submitted,
            screen: "~/app on main\n❯",
            source: ScreenCommandExtractor(),
            finish: .init(directory: "/app", exitCode: 0, finishedAt: now, duration: 0.01)
        ))
        #expect(entry.command == "clear")
    }

    @Test
    func the_submitted_line_wins_and_the_screen_gives_only_its_own_output() throws {
        // A log line that looks like a prompt line (`% make`) fools the screen.
        let screen = """
        app % ./ci.sh
        % make
        error: 1 failed
        app %
        """
        let entry = try #require(ProjectMemory.makeEntry(
            submitted: ScreenCommandExtractor.sentCommand("./ci.sh\n"),
            screen: screen,
            source: ScreenCommandExtractor(),
            finish: .init(directory: nil, exitCode: 2, finishedAt: now, duration: 1)
        ))
        #expect(entry.command == "./ci.sh")
        // The screen's guess is `make`, not this command, so its output is not kept.
        #expect(entry.failureTail == nil)

        let matching = try #require(ProjectMemory.makeEntry(
            submitted: ScreenCommandExtractor.sentCommand("make test\n"),
            screen: "app % make test\nerror: 1 failed\napp %",
            source: ScreenCommandExtractor(),
            finish: .init(directory: nil, exitCode: 2, finishedAt: now, duration: 1)
        ))
        #expect(matching.failureTail == "error: 1 failed")
    }

    @Test
    func a_cursor_cut_command_is_completed_from_the_screen() throws {
        let entry = try #require(ProjectMemory.makeEntry(
            submitted: ScreenCommandExtractor.typedCommand(onScreen: "$ rm -rf build dist", cursorColumn: 12, columns: 80),
            screen: "$ rm -rf build dist\nremoved 2\n$",
            source: ScreenCommandExtractor(),
            finish: .init(directory: nil, exitCode: 0, finishedAt: now, duration: 1)
        ))
        #expect(entry.command == "rm -rf build dist")
    }

    @Test
    func a_right_prompt_keeps_the_command_and_its_output() throws {
        let screen = "~/app> make test        11:23:45 AM\nerror: 1 failed\n~/app>"
        let entry = try #require(ProjectMemory.makeEntry(
            submitted: ScreenCommandExtractor.typedCommand(onScreen: "~/app> make test        11:23:45 AM", cursorColumn: 16, columns: 80),
            screen: screen,
            source: ScreenCommandExtractor(),
            finish: .init(directory: nil, exitCode: 2, finishedAt: now, duration: 1)
        ))
        #expect(entry.command == "make test")
        #expect(entry.failureTail == "error: 1 failed")
    }

    @Test
    func a_submission_long_before_the_command_started_is_not_its_line() {
        let submittedAt = now
        #expect(ProjectMemory.submission(at: submittedAt, matches: now.addingTimeInterval(0.3)))
        #expect(!ProjectMemory.submission(at: submittedAt, matches: now.addingTimeInterval(5)))
    }

    @Test
    func a_masked_command_is_never_offered_to_run_again() {
        let entries = [
            entry("export TOKEN=•••", exit: 1, minutesAgo: 5),
            entry("curl -u me:••• https://x", exit: 0, minutesAgo: 3),
            entry("curl -u me:••• https://x", exit: 0, minutesAgo: 1),
        ]
        let actions = QuickActionRanker.actions(entries: entries, git: nil, now: now)
        #expect(actions.isEmpty)
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "export TOKEN=•••")
    }

    private func makeBackgroundMemory(runs: @escaping @MainActor () -> Void) -> (ProjectMemory, ProjectMemorySummarizer, Project) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-bg-\(UUID().uuidString)", isDirectory: true)
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let summarizer = ProjectMemorySummarizer()
        summarizer.debounce = .milliseconds(10)
        summarizer.loadStored = { _ in nil }
        summarizer.storeSummary = { _, _ in }
        summarizer.suggester = { _, _ in [] }
        summarizer.streamer = { _, _, _ in
            runs()
            return AsyncThrowingStream { continuation in
                continuation.yield("You built the project.")
                continuation.finish()
            }
        }
        memory.summarizer = summarizer
        memory.summaryAllowed = { true }
        memory.gitReader = { _ in nil }
        memory.summaryQuietPeriod = .milliseconds(40)
        let project = Project(name: "acme", path: "/tmp", sortOrder: 0)
        memory.projectLookup = { $0 == project.id ? project : nil }
        return (memory, summarizer, project)
    }

    private func waitForSummary(_ summarizer: ProjectMemorySummarizer, _ project: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while summarizer.state(for: project).phase != .done, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(summarizer.state(for: project).phase == .done)
    }

    @Test
    func a_quiet_project_gets_its_summary_in_the_background_once() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        memory.store.append(entry("make build", exit: 0), to: project.id)

        // Two commands close together: the second restarts the wait.
        memory.scheduleBackgroundSummary(project.id)
        try await Task.sleep(for: .milliseconds(20))
        memory.scheduleBackgroundSummary(project.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(summarizer.state(for: project.id).phase == .idle)

        try await waitForSummary(summarizer, project.id)
        #expect(summarizer.state(for: project.id).text == "You built the project.")
        #expect(runs == 1)
    }

    @Test
    func a_git_state_the_summary_has_not_seen_schedules_the_background_summary() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        var git = GitStatus(branch: "main")
        memory.gitReader = { _ in git }

        // No command at all: the Git state alone is the digest.
        memory.refreshGit(project.id)
        try await waitForSummary(summarizer, project.id)
        #expect(runs == 1)

        // The same state again: nothing new to say.
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(80))
        #expect(runs == 1)

        // A commit moved a branch: news.
        git.branches = [GitStatus.Branch(name: "main", hash: "abc1234", subject: "Fix", lastCommit: now, worktree: nil)]
        memory.refreshGit(project.id)
        let deadline = Date().addingTimeInterval(5)
        while runs < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(runs == 2)
    }

    @Test
    func the_button_writes_a_summary_now_and_again_for_the_same_records() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        memory.store.append(entry("make build", exit: 0), to: project.id)

        await memory.writeSummary(project.id, force: true)
        try await waitForSummary(summarizer, project.id)
        await memory.writeSummary(project.id, force: true)
        try await waitForSummary(summarizer, project.id)
        #expect(runs == 2)
        // The quiet period, for records that have a summary, costs nothing.
        await memory.writeSummary(project.id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(runs == 2)
    }

    @Test
    func a_project_list_that_did_not_load_prunes_nothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-prune-\(UUID().uuidString)", isDirectory: true)
        let store = ProjectMemoryStore(directory: directory)
        let project = UUID()
        store.append(entry("make", exit: 0), to: project)
        store.flush()
        let badFile = FileManager.default.temporaryDirectory.appendingPathComponent("macterm-bad-projects-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: badFile)
        let projectStore = ProjectStore(fileURL: badFile)
        #expect(projectStore.loadFailed)

        ProjectMemory(store: store).attach(projectStore: projectStore) { _ in false }

        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: project).path))
    }

    @Test
    func a_submitted_line_with_a_leading_space_is_private() {
        #expect(ScreenCommandExtractor.sentCommand(" export TOKEN=x\n")?.isPrivate == true)
        #expect(ScreenCommandExtractor.typedCommand(onScreen: "app %  export TOKEN=x")?.isPrivate == true)
        #expect(ProjectMemory.makeEntry(
            submitted: ScreenCommandExtractor.sentCommand(" export TOKEN=x\n"),
            screen: nil,
            source: ScreenCommandExtractor(),
            finish: .init(directory: nil, exitCode: 0, finishedAt: now, duration: 1)
        ) == nil)
    }

    @Test
    func a_prompt_line_with_no_command_captures_nothing() {
        #expect(ScreenCommandExtractor.typedCommand(onScreen: "output\napp %") == nil)
        #expect(ScreenCommandExtractor.typedCommand(onScreen: "plain text with no mark") == nil)
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

    // MARK: - Remote git

    private func makeRemoteMemory() -> (ProjectMemory, Project) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-remote-\(UUID().uuidString)", isDirectory: true)
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let project = Project(name: "api", path: "me@devbox:~/dev/api", sortOrder: 0)
        memory.projectLookup = { $0 == project.id ? project : nil }
        memory.gitReader = { _ in Issue.record("a remote project never reads git locally")
            return nil
        }
        memory.remoteGitAllowed = { true }
        return (memory, project)
    }

    private func waitForGitRead(_ memory: ProjectMemory, _ project: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while memory.readingGit.contains(project) || memory.git[project] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func a_remote_project_reads_git_over_ssh_and_keeps_the_last_state_when_unreachable() async throws {
        let (memory, project) = makeRemoteMemory()
        var reads: [ProjectPath] = []
        var answer: ProjectGit.RemoteResult = .read(GitStatus(branch: "main"))
        memory.remoteGitReader = { remote in reads.append(remote)
            return answer
        }

        memory.refreshGit(project.id)
        try await waitForGitRead(memory, project.id)
        #expect(reads == [.remote(user: "me", host: "devbox", directory: "~/dev/api")])
        #expect(memory.git[project.id]?.branch == "main")

        answer = .unreachable
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads.count == 2)
        #expect(memory.git[project.id]?.branch == "main")
        #expect(memory.gitUnavailability(for: project) == nil)
    }

    @Test
    func background_ssh_off_reads_nothing_and_says_why() async throws {
        let (memory, project) = makeRemoteMemory()
        memory.remoteGitAllowed = { false }
        var reads = 0
        memory.remoteGitReader = { _ in reads += 1
            return .read(nil)
        }
        #expect(memory.gitUnavailability(for: project) == .backgroundSSHOff)
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 0)
        #expect(memory.git[project.id] == nil)
    }

    @Test
    func a_refused_login_suspends_the_host_for_the_run() async throws {
        let (memory, project) = makeRemoteMemory()
        var reads = 0
        memory.remoteGitReader = { _ in reads += 1
            return .authRefused
        }
        memory.refreshGit(project.id)
        let deadline = Date().addingTimeInterval(5)
        while memory.refusedRemoteHosts.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(memory.refusedRemoteHosts == ["me@devbox"])
        #expect(memory.gitUnavailability(for: project) == .refused(host: "me@devbox"))

        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 1)

        // A local project is never gated.
        let local = Project(name: "app", path: "/tmp", sortOrder: 1)
        #expect(memory.gitUnavailability(for: local) == nil)
    }
}
