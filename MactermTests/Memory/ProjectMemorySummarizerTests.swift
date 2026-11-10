import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectMemorySummarizerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A stand-in model that streams `reply` in two parts and counts its runs.
    @MainActor
    final class FakeModel {
        var runs = 0
        var prompts: [String] = []
        var reply = "You were fixing the checkout tests."
        var fails = false
        var suggestions: [OnDeviceModel.Suggestion] = [OnDeviceModel.Suggestion(command: "make build", reason: "Build first.")]
        var suggestionRuns = 0
        var suggestionsFail = false

        func suggest(_: String, _: String) async throws -> [OnDeviceModel.Suggestion] {
            suggestionRuns += 1
            if suggestionsFail { throw OnDeviceModel.Failure.other }
            return suggestions
        }

        func stream(_: String, prompt: String, _: Int) -> AsyncThrowingStream<String, Error> {
            runs += 1
            prompts.append(prompt)
            let reply = reply
            let fails = fails
            return AsyncThrowingStream { continuation in
                if fails {
                    continuation.finish(throwing: OnDeviceModel.Failure.other)
                    return
                }
                continuation.yield(String(reply.prefix(8)))
                continuation.yield(reply)
                continuation.finish()
            }
        }
    }

    /// A stand-in for the memory file.
    @MainActor
    final class FakeStorage {
        var stored: [UUID: StoredSummary] = [:]
    }

    private func makeSummarizer(_ model: FakeModel, storage: FakeStorage = FakeStorage()) -> ProjectMemorySummarizer {
        let summarizer = ProjectMemorySummarizer()
        summarizer.debounce = .milliseconds(10)
        summarizer.streamer = { instructions, prompt, tokens in model.stream(instructions, prompt: prompt, tokens) }
        summarizer.loadStored = { storage.stored[$0] }
        summarizer.storeSummary = { storage.stored[$0] = $1 }
        summarizer.suggester = { instructions, prompt in try await model.suggest(instructions, prompt) }
        return summarizer
    }

    /// The same commands give the same entries, ids included: a key is the
    /// records' ids, so a digest of the same list must be the same digest.
    private func digest(_ commands: [String]) -> ProjectMemoryDigest {
        let entries = commands.enumerated().map { index, command in
            MemoryEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                command: command,
                directory: nil,
                exitCode: 0,
                finishedAt: now.addingTimeInterval(Double(index)),
                duration: 1
            )
        }
        return ProjectMemoryDigest(projectName: "acme", entries: entries, git: nil, now: now)!
    }

    private func wait(for summarizer: ProjectMemorySummarizer, _ project: UUID, phase: ProjectMemorySummarizer.Phase) async throws {
        let deadline = Date().addingTimeInterval(5)
        while summarizer.state(for: project).phase != phase, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(summarizer.state(for: project).phase == phase)
    }

    @Test
    func a_summary_streams_in_and_is_kept_for_the_same_digest() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        let project = UUID()

        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        #expect(summarizer.state(for: project).phase == .waiting)
        try await wait(for: summarizer, project, phase: .done)
        #expect(summarizer.state(for: project).text == model.reply)
        #expect(model.prompts.first?.contains("`make build`") == true)

        // The same digest never runs the model again.
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.runs == 1)
        #expect(summarizer.state(for: project).phase == .done)
    }

    @Test
    func a_new_digest_runs_again_and_keeps_the_old_text_while_it_waits() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .done)

        model.reply = "Now the tests fail."
        summarizer.refresh(projectID: project, digest: digest(["make build", "make test"]))
        let waiting = summarizer.state(for: project)
        #expect(waiting.phase == .waiting)
        #expect(waiting.text == "You were fixing the checkout tests.")
        try await wait(for: summarizer, project, phase: .done)
        #expect(summarizer.state(for: project).text == "Now the tests fail.")
        #expect(model.runs == 2)
    }

    @Test
    func a_burst_of_digests_runs_the_model_once() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        let project = UUID()
        for count in 1 ... 5 {
            summarizer.refresh(projectID: project, digest: digest((0 ..< count).map { "cmd \($0)" }))
        }
        try await wait(for: summarizer, project, phase: .done)
        #expect(model.runs == 1)
        #expect(model.prompts.first?.contains("`cmd 4`") == true)
    }

    @Test
    func a_failed_run_is_failed_and_runs_again_on_the_next_refresh() async throws {
        let model = FakeModel()
        model.fails = true
        let summarizer = makeSummarizer(model)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .failed)
        #expect(summarizer.state(for: project).text.isEmpty)

        model.fails = false
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .done)
        #expect(model.runs == 2)
    }

    @Test
    func a_finished_summary_is_stored_and_seeds_the_next_launch() async throws {
        let model = FakeModel()
        let storage = FakeStorage()
        let project = UUID()
        let first = makeSummarizer(model, storage: storage)
        first.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: first, project, phase: .done)
        #expect(storage.stored[project]?.text == model.reply)
        #expect(storage.stored[project]?.key == digest(["make build"]).key)

        // A new summarizer (a relaunch) shows the stored text with no run.
        let second = makeSummarizer(model, storage: storage)
        second.refresh(projectID: project, digest: digest(["make build"]))
        #expect(second.state(for: project) == .init(
            phase: .done, text: model.reply, key: digest(["make build"]).key, suggestions: model.suggestions
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.runs == 1)

        // Records that changed since run again.
        second.refresh(projectID: project, digest: digest(["make build", "make test"]))
        try await wait(for: second, project, phase: .done)
        #expect(model.runs == 2)
    }

    @Test
    func suggestions_follow_the_text_and_are_stored_with_it() async throws {
        let model = FakeModel()
        let storage = FakeStorage()
        let summarizer = makeSummarizer(model, storage: storage)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .done)
        #expect(summarizer.state(for: project).suggestions == model.suggestions)
        #expect(model.suggestionRuns == 1)
        #expect(storage.stored[project]?.suggestions == [StoredSuggestion(command: "make build", reason: "Build first.")])

        // A relaunch has them with the text.
        let second = makeSummarizer(model, storage: storage)
        second.refresh(projectID: project, digest: digest(["make build"]))
        #expect(second.state(for: project).suggestions == model.suggestions)
    }

    @Test
    func a_secret_in_a_hunk_reaches_the_model_but_not_the_summary() async throws {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123"
        var git = GitStatus(branch: "main", unstaged: 1, changedPaths: ["deploy.sh"])
        git.diff = [GitStatus.FileDiff(path: "deploy.sh", lines: ["@@ -1 +1 @@", "+export GITHUB_TOKEN=\(secret)"])]
        let digest = try #require(ProjectMemoryDigest(projectName: "acme", entries: [], git: git, now: now))
        let model = FakeModel()
        model.reply = "You set `GITHUB_TOKEN=\(secret)` in `deploy.sh`."
        model.suggestions = [OnDeviceModel.Suggestion(command: "git diff", reason: "Check \(secret) before a commit.")]
        let storage = FakeStorage()
        let summarizer = makeSummarizer(model, storage: storage)
        let project = UUID()

        summarizer.refresh(projectID: project, digest: digest)
        try await wait(for: summarizer, project, phase: .done)
        #expect(model.prompts.first?.contains(secret) == true)
        let state = summarizer.state(for: project)
        #expect(state.text == "You set `GITHUB_TOKEN=\(MemoryRedaction.mask)` in `deploy.sh`.")
        #expect(state.suggestions.allSatisfy { !$0.reason.contains(secret) })
        let stored = try #require(storage.stored[project])
        #expect(!stored.text.contains(secret))
        #expect(stored.suggestions?.allSatisfy { !$0.reason.contains(secret) } == true)
    }

    @Test
    func a_failed_suggestion_request_keeps_the_text() async throws {
        let model = FakeModel()
        model.suggestionsFail = true
        let summarizer = makeSummarizer(model)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .done)
        #expect(summarizer.state(for: project).text == model.reply)
        #expect(summarizer.state(for: project).suggestions.isEmpty)
    }

    @Test
    func force_writes_the_same_records_again() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        try await wait(for: summarizer, project, phase: .done)
        summarizer.refresh(projectID: project, digest: digest(["make build"]), force: true)
        #expect(summarizer.state(for: project).phase == .waiting)
        try await wait(for: summarizer, project, phase: .done)
        #expect(model.runs == 2)
    }

    @Test
    func the_same_records_an_hour_later_do_not_run_again() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        let project = UUID()
        let entries = [MemoryEntry(command: "make", directory: nil, exitCode: 0, finishedAt: now, duration: 1)]
        summarizer.refresh(projectID: project, digest: ProjectMemoryDigest(projectName: "acme", entries: entries, git: nil, now: now))
        try await wait(for: summarizer, project, phase: .done)
        summarizer.refresh(
            projectID: project,
            digest: ProjectMemoryDigest(projectName: "acme", entries: entries, git: nil, now: now.addingTimeInterval(3600))
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.runs == 1)
    }

    @Test
    func nothing_to_say_clears_the_summary_and_cancel_stops_a_run() async throws {
        let model = FakeModel()
        let summarizer = makeSummarizer(model)
        summarizer.debounce = .seconds(2)
        let project = UUID()
        summarizer.refresh(projectID: project, digest: digest(["make build"]))
        summarizer.cancel(projectID: project)
        #expect(summarizer.state(for: project).phase == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.runs == 0)

        summarizer.refresh(projectID: project, digest: nil)
        #expect(summarizer.state(for: project) == ProjectMemorySummarizer.State())
    }
}
