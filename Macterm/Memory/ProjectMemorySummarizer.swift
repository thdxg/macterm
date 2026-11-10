import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectMemorySummarizer")

/// Writes the paragraph at the top of the memory panel: where the user left
/// off in a project, from `ProjectMemoryDigest`, by Apple's on-device model
/// (`OnDeviceModel`). Nothing leaves the Mac.
///
/// One summary for each project, keyed by `ProjectMemoryDigest.key`: the
/// same log and git state never run the model twice, so a panel that opens
/// again shows its summary at once. A finished summary is stored with the
/// project's memory (`StoredSummary`), so a relaunch shows it too. A new
/// digest cancels the run in flight and starts another after `debounce`, so
/// a burst of commands runs the model once. The old text stays up until the
/// new one streams in.
@MainActor @Observable
final class ProjectMemorySummarizer {
    static let shared = ProjectMemorySummarizer()

    enum Phase: String {
        case idle
        /// A run is scheduled or the model has not written yet.
        case waiting
        case streaming
        case done
        case failed
    }

    struct State: Equatable {
        var phase = Phase.idle
        /// The reply so far, or the last reply while a new one waits.
        var text = ""
        /// The `ProjectMemoryDigest.key` that the run is for.
        var key: String?
        /// What the model suggested, raw; `ProjectMemorySuggestions.actions`
        /// keeps the known ones.
        var suggestions: [OnDeviceModel.Suggestion] = []
    }

    private(set) var states: [UUID: State] = [:]

    /// The model's stream, as a seam for the tests.
    @ObservationIgnored var streamer: (_ instructions: String, _ prompt: String, _ maximumResponseTokens: Int)
        -> AsyncThrowingStream<String, Error> = { instructions, prompt, tokens in
            OnDeviceModel.stream(instructions: instructions, prompt: prompt, maximumResponseTokens: tokens)
        }

    /// The model's typed suggestions, as a seam for the tests.
    @ObservationIgnored var suggester: (_ instructions: String, _ prompt: String) async throws -> [OnDeviceModel.Suggestion] = {
        try await OnDeviceModel.suggestCommands(instructions: $0, prompt: $1)
    }

    @ObservationIgnored var debounce: Duration = .milliseconds(1500)
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Where a finished summary is kept and read back: the project's memory
    /// file, through `ProjectMemory.shared.store`. Seams for the tests.
    @ObservationIgnored var loadStored: (UUID) -> StoredSummary? = { ProjectMemory.shared.store.summary(for: $0) }
    @ObservationIgnored var storeSummary: (UUID, StoredSummary) -> Void = { ProjectMemory.shared.store.setSummary($1, for: $0) }

    init() {}

    /// Whether the panel shows a summary: memory is on and the model can
    /// run. The model is asked again here, because the DEBUG
    /// `project memory` verb turns memory on without it.
    static var isEnabled: Bool {
        ProjectMemory.isEnabled && OnDeviceModel.availability == .available
    }

    func state(for projectID: UUID) -> State {
        states[projectID] ?? State()
    }

    /// The state, seeded from the stored summary the first time.
    private func currentState(for projectID: UUID) -> State? {
        if let state = states[projectID] { return state }
        guard let stored = loadStored(projectID) else { return nil }
        let suggestions = (stored.suggestions ?? []).map { OnDeviceModel.Suggestion(command: $0.command, reason: $0.reason) }
        let state = State(phase: .done, text: stored.text, key: stored.key, suggestions: suggestions)
        states[projectID] = state
        return state
    }

    /// Load the stored summary into the state, for a view that reads it.
    /// Outside a view update, as a `.task`.
    func prepare(projectID: UUID) {
        _ = currentState(for: projectID)
    }

    /// Write a summary for `digest`, unless the one shown is for the same
    /// digest already; `force` writes it again anyway (the panel's button).
    /// nil clears the summary: there is nothing to say.
    func refresh(projectID: UUID, digest: ProjectMemoryDigest?, force: Bool = false) {
        guard let digest else {
            tasks.removeValue(forKey: projectID)?.cancel()
            states[projectID] = State()
            return
        }
        if !force, let current = currentState(for: projectID), current.key == digest.key, current.phase != .failed {
            return
        }
        tasks[projectID]?.cancel()
        states[projectID] = State(
            phase: .waiting, text: states[projectID]?.text ?? "", key: digest.key, suggestions: states[projectID]?.suggestions ?? []
        )
        tasks[projectID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let stream = streamer(ProjectMemoryDigest.instructions, digest.prompt, ProjectMemoryDigest.maximumReplyTokens)
            do {
                var reply = ""
                for try await partial in stream {
                    guard !Task.isCancelled else { return }
                    reply = partial
                    // The old text stays up until a whole word streams in.
                    guard !Self.completeWords(partial).isEmpty else { continue }
                    states[projectID] = State(
                        phase: .streaming,
                        text: Self.redacted(Self.completeWords(partial)),
                        key: digest.key,
                        suggestions: states[projectID]?.suggestions ?? []
                    )
                }
                // A cancelled loop ends with no error.
                guard !Task.isCancelled else { return }
                let text = Self.redacted(reply)
                guard !text.isEmpty else {
                    states[projectID] = State(phase: .failed, text: "", key: digest.key)
                    return
                }
                // The suggestions, after the text: a second request. A failure
                // here keeps the text; the panel then shows its own rows.
                let suggestions = await ((try? suggester(ProjectMemoryDigest.suggestionInstructions, digest.suggestionPrompt)) ?? [])
                    .map { OnDeviceModel.Suggestion(command: $0.command, reason: Self.redacted($0.reason)) }
                guard !Task.isCancelled else { return }
                states[projectID] = State(phase: .done, text: text, key: digest.key, suggestions: suggestions)
                storeSummary(projectID, StoredSummary(
                    key: digest.key,
                    text: text,
                    writtenAt: Date(),
                    suggestions: suggestions.map { StoredSuggestion(command: $0.command, reason: $0.reason) }
                ))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.info("summary failed: \(EnglishErrorText.describe(error), privacy: .public)")
                states[projectID] = State(phase: .failed, text: "", key: digest.key)
            }
        }
    }

    /// The model's text, and the reason of each suggestion, with every secret
    /// masked (`MemoryRedaction`), before it is shown or stored. The diff in
    /// the prompts is not redacted, so a secret in it could reach a reply.
    static func redacted(_ text: String) -> String {
        MemoryRedaction.redact(text)
    }

    /// `partial` up to its last whitespace. A secret streams in a token at
    /// a time, and the redaction knows a key only at its full length, so
    /// the last word shows only when the next one starts.
    static func completeWords(_ partial: String) -> String {
        guard let end = partial.lastIndex(where: \.isWhitespace) else { return "" }
        return String(partial[..<end])
    }

    /// Stop a run for a project whose panel went away. The stored summary
    /// comes back at the next open, and a new key runs again.
    func cancel(projectID: UUID) {
        tasks.removeValue(forKey: projectID)?.cancel()
        if states[projectID]?.phase == .waiting || states[projectID]?.phase == .streaming {
            states[projectID] = nil
        }
    }

    /// Delete a project's summary with its memory. The store drops the
    /// stored one with the file.
    func forget(projectID: UUID) {
        tasks.removeValue(forKey: projectID)?.cancel()
        states[projectID] = nil
    }

    func forgetAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        states.removeAll()
    }
}
