import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectMemory")

/// Project memory: what happened in each project, and what the panel says
/// about it (`ProjectMemoryPanel`).
///
/// - Records each command that finishes in a project's pane
///   (`commandFinished`), as a `MemoryEntry` in the project's file
///   (`ProjectMemoryStore`). Never the scrollback.
/// - Reads the project's git state (`ProjectGit`), cached for each project.
///
/// macOS 26 and later only (`isSupported`), and off until the user turns it
/// on (`Preferences.projectMemory`). The pinned and scratch workspaces, the
/// quick terminal and desktop widgets are not projects, and are never
/// recorded.
@MainActor @Observable
final class ProjectMemory {
    static let shared = ProjectMemory()

    let store: ProjectMemoryStore
    /// The last git state of each local project that the panel showed.
    private(set) var git: [UUID: GitStatus] = [:]
    /// The projects whose git state is being read.
    private(set) var readingGit: Set<UUID> = []

    @ObservationIgnored var textSource: any CommandTextSource = ScreenCommandExtractor()
    /// How long after OSC 133;D the screen is read. The shell sends the mark
    /// before it prints its next prompt, and the extractor needs that prompt.
    @ObservationIgnored var screenReadDelay = Duration.milliseconds(400)
    @ObservationIgnored var gitReader: (String) async -> GitStatus? = { await ProjectGit.status(at: $0) }
    @ObservationIgnored private var pendingGitReads: [UUID: Task<Void, Never>] = [:]

    init(store: ProjectMemoryStore = ProjectMemoryStore()) {
        self.store = store
    }

    /// Whether this Mac has the feature at all.
    nonisolated static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Whether commands are recorded now.
    static var isRecording: Bool {
        isSupported && Preferences.shared.projectMemory
    }

    /// Whether a workspace is a project that memory covers.
    static func covers(_ projectID: UUID) -> Bool {
        !Project.isSynthetic(projectID)
            && projectID != QuickTerminalService.projectID
            && projectID != DesktopWidget.projectID
    }

    // MARK: - Recording

    /// The command line of each pane's running command, captured when it
    /// was submitted (`commandSubmitted`), by pane id.
    @ObservationIgnored private var submittedCommands: [UUID: ExtractedCommand] = [:]

    /// The user pressed Return, or `pane run` sent a line, in `pane`. While
    /// the shell is at its prompt, that line is the command that is about to
    /// run: keep it for `commandFinished`. Read now, because a command that
    /// clears the screen or prints more than a screen takes it away. A Return
    /// inside a program (an editor, a REPL) is not at the prompt and is
    /// ignored.
    func commandSubmitted(pane: Pane, view: GhosttyTerminalNSView?) {
        guard Self.isRecording, Self.covers(pane.projectID), pane.isShellAtPrompt, let view else { return }
        let line: ExtractedCommand? = if let sent = view.submittedText {
            ScreenCommandExtractor.sentCommand(sent)
        } else {
            view.readText(area: GHOSTTY_POINT_ACTIVE).flatMap(ScreenCommandExtractor.typedCommand(onScreen:))
        }
        submittedCommands[pane.id] = line
    }

    /// A command finished in `pane` (OSC 133;D). Records it after the next
    /// prompt is on the screen.
    func commandFinished(pane: Pane, view: GhosttyTerminalNSView?, exitCode: Int16, durationNs: UInt64) {
        // Taken now: the next command's Return can come before the read.
        let submitted = submittedCommands.removeValue(forKey: pane.id)
        guard Self.isRecording, Self.covers(pane.projectID) else { return }
        let projectID = pane.projectID
        let finishedAt = Date()
        let directory = view?.currentPwd
        let code: Int? = exitCode < 0 ? nil : Int(exitCode)
        let duration = Double(durationNs) / 1_000_000_000
        Task { [weak self, weak view] in
            guard let self else { return }
            try? await Task.sleep(for: screenReadDelay)
            // A prompt that asks for a password owns the screen's last line,
            // so the screen says nothing about the command.
            let promptUp = view.map { ["sighted", "prompting"].contains(PasswordPromptMonitor.shared.state(for: $0).phase) } ?? false
            let screen = promptUp ? nil : view?.readText(area: GHOSTTY_POINT_ACTIVE)
            let finish = Finish(directory: directory, exitCode: code, finishedAt: finishedAt, duration: duration)
            guard let entry = Self.makeEntry(submitted: submitted, screen: screen, source: textSource, finish: finish)
            else { return }
            store.append(entry, to: projectID)
            logger.debug("recorded a command in \(projectID, privacy: .public)")
            refreshGit(projectID, after: .seconds(2))
        }
    }

    /// What OSC 133;D says about a finished command, with the shell's folder.
    struct Finish {
        var directory: String?
        /// nil when the shell reported none.
        var exitCode: Int?
        var finishedAt: Date
        /// Seconds.
        var duration: TimeInterval
    }

    /// The entry for a finished command, or nil when there is nothing to
    /// remember: the user asked the shell not to (a leading space), or
    /// neither the submitted line nor the screen says what the command was.
    /// A record with no command is noise in every list that shows it.
    ///
    /// The line captured at submission wins over the screen: it is what was
    /// typed, and output that looks like a prompt line cannot replace it. The
    /// screen gives the output tail, and only when it shows that same
    /// command. Pure, for the tests.
    nonisolated static func makeEntry(
        submitted: ExtractedCommand? = nil,
        screen: String?,
        source: any CommandTextSource,
        finish: Finish
    ) -> MemoryEntry? {
        let extracted = screen.flatMap(source.extract(screen:))
        guard let command = submitted ?? extracted, !command.isPrivate else { return nil }
        let output = extracted.flatMap { screenCommand in
            QuickActionRanker.normalized(screenCommand.command) == QuickActionRanker.normalized(command.command)
                ? screenCommand.output
                : nil
        }
        var entry = MemoryEntry(
            command: MemoryRedaction.redact(command.command),
            directory: finish.directory,
            exitCode: finish.exitCode,
            finishedAt: finish.finishedAt,
            duration: finish.duration
        )
        if entry.outcome == .failure, let output, let tail = MemoryEntry.tail(of: output) {
            entry.failureTail = MemoryRedaction.redact(tail)
        }
        return entry
    }

    // MARK: - Git

    /// Read a local project's git state again, after `delay`. A read that is
    /// already waiting is replaced.
    func refreshGit(_ projectID: UUID, after delay: Duration = .zero) {
        guard let project = projectLookup(projectID), !project.isRemote else { return }
        let path = project.path
        pendingGitReads[projectID]?.cancel()
        pendingGitReads[projectID] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            readingGit.insert(projectID)
            let status = await gitReader(path)
            readingGit.remove(projectID)
            guard !Task.isCancelled else { return }
            git[projectID] = status
            pendingGitReads[projectID] = nil
        }
    }

    /// Delete a project's memory and its cached git state.
    func forget(_ projectID: UUID) {
        store.forget(projectID)
        git[projectID] = nil
    }

    func forgetAll() {
        store.forgetAll()
        git.removeAll()
    }

    /// Project lookup for the git read. Set by `attach`.
    @ObservationIgnored var projectLookup: (UUID) -> Project? = { _ in nil }

    /// Hand the feature the project list, and delete the memory of projects
    /// that were removed while Macterm was not running.
    func attach(projectStore: ProjectStore) {
        projectLookup = { [weak projectStore] id in projectStore?.projects.first { $0.id == id } }
        guard Self.isSupported else { return }
        store.prune(keeping: Set(projectStore.projects.map(\.id)))
    }
}
