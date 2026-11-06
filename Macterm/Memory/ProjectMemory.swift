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
    /// The git state of a remote project, over one background ssh
    /// connection (`ProjectGit.remoteStatus`).
    @ObservationIgnored var remoteGitReader: (ProjectPath) async -> ProjectGit.RemoteResult = { await ProjectGit.remoteStatus($0) }
    /// Whether a background ssh connection may be made at all (#272): the
    /// kill switch of every background connection to a host.
    @ObservationIgnored var remoteGitAllowed: () -> Bool = { Preferences.shared.backgroundSSHConnections }
    /// The ssh destinations that refused the background login in this run
    /// (`ProjectGit.RemoteResult.authRefused`). No git read goes to them
    /// again, as the foreground probe suspends them too.
    private(set) var refusedRemoteHosts: Set<String> = []
    @ObservationIgnored private var pendingGitReads: [UUID: Task<Void, Never>] = [:]

    /// How long a project is quiet after its last command before its
    /// summary is written in the background (`scheduleBackgroundSummary`),
    /// so that a panel opened after a break shows it at once.
    @ObservationIgnored var summaryQuietPeriod: Duration = .seconds(600)
    @ObservationIgnored var summarizer: ProjectMemorySummarizer = .shared
    @ObservationIgnored var summaryAllowed: () -> Bool = { ProjectMemorySummarizer.isEnabled }
    @ObservationIgnored private var quietTimers: [UUID: Task<Void, Never>] = [:]

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

    /// A command line captured at submission, for the finish that follows.
    struct Submission {
        var line: ExtractedCommand?
        var at: Date
    }

    /// The command line of each pane's running command, captured when it
    /// was submitted (`commandSubmitted`), by pane id.
    @ObservationIgnored private var submittedCommands: [UUID: Submission] = [:]

    /// How long after a submission its command must have started for the
    /// two to be the same command. A shell sends OSC 133;C within
    /// milliseconds of Return. A submission whose end mark never came (an
    /// ssh that dropped, `exec zsh`) must not name the next command.
    nonisolated static let submissionTolerance: TimeInterval = 2

    /// Whether a window shows the memory panel for a project. Set by
    /// `attach`; the git state is read after a command only where someone
    /// looks at it.
    @ObservationIgnored var panelShows: (UUID) -> Bool = { _ in false }

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
            view.readText(area: GHOSTTY_POINT_ACTIVE).flatMap {
                ScreenCommandExtractor.typedCommand(
                    onScreen: $0,
                    cursorColumn: view.cursorColumn(),
                    columns: view.surfaceSize.map { Int($0.columns) }
                )
            }
        }
        submittedCommands[pane.id] = Submission(line: line, at: Date())
    }

    /// Whether a submission at `submittedAt` is the command that started at
    /// `startedAt`. Pure, for the tests.
    nonisolated static func submission(at submittedAt: Date, matches startedAt: Date) -> Bool {
        startedAt.timeIntervalSince(submittedAt) < submissionTolerance
    }

    /// A command finished in `pane` (OSC 133;D). Records it after the next
    /// prompt is on the screen.
    /// `reportedCommand` is the command as libghostty read it from the
    /// prompt's input cells at the start of the output (fork patch 0019).
    /// It wins over the submission and the screen. nil when the shell
    /// marked no input: the submission and the screen then answer.
    func commandFinished(
        pane: Pane, view: GhosttyTerminalNSView?, exitCode: Int16, durationNs: UInt64, reportedCommand: String? = nil
    ) {
        // Taken now: the next command's Return can come before the read.
        let submission = submittedCommands.removeValue(forKey: pane.id)
        guard Self.isRecording, Self.covers(pane.projectID) else { return }
        let projectID = pane.projectID
        let finishedAt = Date()
        let directory = view?.currentPwd
        let code: Int? = exitCode < 0 ? nil : Int(exitCode)
        let duration = Double(durationNs) / 1_000_000_000
        let startedAt = finishedAt.addingTimeInterval(-duration)
        let submitted = submission.flatMap { Self.submission(at: $0.at, matches: startedAt) ? $0.line : nil }
        let reported = reportedCommand.flatMap(Self.reportedCommand)
        Task { [weak self, weak view] in
            guard let self else { return }
            try? await Task.sleep(for: screenReadDelay)
            // A prompt that asks for a password owns the screen's last line,
            // so the screen says nothing about the command.
            let promptUp = view.map { ["sighted", "prompting"].contains(PasswordPromptMonitor.shared.state(for: $0).phase) } ?? false
            let screen = promptUp ? nil : view?.readText(area: GHOSTTY_POINT_ACTIVE)
            let finish = Finish(directory: directory, exitCode: code, finishedAt: finishedAt, duration: duration)
            guard let entry = Self.makeEntry(
                reported: reported, submitted: submitted, screen: screen, source: textSource, finish: finish
            )
            else { return }
            store.append(entry, to: projectID)
            logger.debug("recorded a command in \(projectID, privacy: .public)")
            if panelShows(projectID) { refreshGit(projectID, after: .seconds(2)) }
            scheduleBackgroundSummary(projectID)
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

    /// The command that libghostty reported, as a command: the typed text
    /// with its trailing spaces dropped, private when it starts with a
    /// space (`HISTCONTROL=ignorespace`). nil for text with no command.
    nonisolated static func reportedCommand(_ text: String) -> ExtractedCommand? {
        let isPrivate = text.hasPrefix(" ")
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return ExtractedCommand(command: command, output: "", isPrivate: isPrivate)
    }

    /// The entry for a finished command, or nil when there is nothing to
    /// remember: the user asked the shell not to (a leading space), or
    /// nothing says what the command was. A record with no command is
    /// noise in every list that shows it.
    ///
    /// The command libghostty reported wins: it is the input cells of the
    /// prompt, read before any output. Else the line captured at submission
    /// wins over the screen: it is what was typed, and output that looks
    /// like a prompt line cannot replace it. The screen gives the output
    /// tail, and only when it shows that same command. One exception: when
    /// the screen's command continues the submitted line with no gap, the
    /// cursor cut the line in the middle of the command, and the screen has
    /// the whole of it. Pure, for the tests.
    nonisolated static func makeEntry(
        reported: ExtractedCommand? = nil,
        submitted: ExtractedCommand? = nil,
        screen: String?,
        source: any CommandTextSource,
        finish: Finish
    ) -> MemoryEntry? {
        let extracted = screen.flatMap(source.extract(screen:))
        guard var command = reported ?? submitted ?? extracted, !command.isPrivate else { return nil }
        if reported == nil, let submitted, let extracted,
           ScreenCommandExtractor.screenCommand(extracted.command, extends: submitted.command)
        {
            command.command = extracted.command
        }
        let output = extracted.flatMap { screenCommand in
            ScreenCommandExtractor.screenCommand(screenCommand.command, shows: command.command) ? screenCommand.output : nil
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

    /// Why the panel shows no git state for a project, or nil when a read
    /// is possible.
    enum GitUnavailability: Equatable {
        /// Background ssh connections are off (Settings → General).
        case backgroundSSHOff
        /// The host refused the background login in this run.
        case refused(host: String)
    }

    /// Whether a project's git state can be read now. A local project can
    /// always be read. A remote project needs background ssh connections,
    /// and a host that refused the login once is not asked again.
    func gitUnavailability(for project: Project) -> GitUnavailability? {
        guard case let .remote(user, host, _)? = ProjectPath.parse(project.path) else { return nil }
        guard remoteGitAllowed() else { return .backgroundSSHOff }
        let destination = RemoteSpawn.destination(user: user, host: host)
        return refusedRemoteHosts.contains(destination) ? .refused(host: destination) : nil
    }

    /// Read a project's git state again, after `delay`. A read that is
    /// already waiting is replaced. A remote project is read over ssh
    /// (`gitUnavailability` says when it is not).
    func refreshGit(_ projectID: UUID, after delay: Duration = .zero) {
        guard let project = projectLookup(projectID), gitUnavailability(for: project) == nil else { return }
        pendingGitReads[projectID]?.cancel()
        pendingGitReads[projectID] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            readingGit.insert(projectID)
            let result = await readGit(project)
            // A read that a newer one replaced leaves the mark to that one.
            guard !Task.isCancelled else { return }
            readingGit.remove(projectID)
            apply(result, to: project)
            pendingGitReads[projectID] = nil
            // A Git state the summary has not seen is news as a command is:
            // a commit from another terminal, or a project with no command
            // yet, whose summary is its Git state alone.
            if case .read(.some) = result, gitStateIsNews(for: project) {
                scheduleBackgroundSummary(projectID)
            }
        }
    }

    /// Whether the summary on record was written for another Git state (or
    /// for none), with the records as they are now.
    private func gitStateIsNews(for project: Project) -> Bool {
        let key = ProjectMemoryDigest.key(projectName: project.name, entries: store.entries(for: project.id), git: git[project.id])
        return summarizer.state(for: project.id).key != key
    }

    /// One read of a project's git state, local or remote.
    private func readGit(_ project: Project) async -> ProjectGit.RemoteResult {
        if let remote = ProjectPath.parse(project.path), case .remote = remote {
            return await remoteGitReader(remote)
        }
        return await .read(gitReader(project.path))
    }

    /// What a read leaves behind. An answer replaces the state. No answer
    /// keeps the last one: a flaky link must not blank the panel. A refusal
    /// suspends the host for the run.
    private func apply(_ result: ProjectGit.RemoteResult, to project: Project) {
        switch result {
        case let .read(status):
            git[project.id] = status
        case .unreachable:
            break
        case .authRefused:
            if case let .remote(user, host, _)? = ProjectPath.parse(project.path) {
                let destination = RemoteSpawn.destination(user: user, host: host)
                refusedRemoteHosts.insert(destination)
                logger.info("git read auth refused for \(destination, privacy: .public); not asking again this run")
            }
        }
    }

    /// The rows of the panel's Suggested section: the model's suggestions
    /// (`ProjectMemorySuggestions`), or none. With no model, no summary yet,
    /// or nothing the model suggested that survives the checks, the section
    /// is hidden, as the summary is: a command is never suggested only
    /// because it ran recently or often.
    func suggestedActions(projectID: UUID, entries: [MemoryEntry]) -> [QuickAction] {
        ProjectMemorySuggestions.actions(
            from: summarizer.state(for: projectID).suggestions, entries: entries, git: git[projectID]
        )
    }

    // MARK: - Background summary

    /// Write a project's summary once it has been quiet for `delay`
    /// (`summaryQuietPeriod` when nil), panel or no panel. A new command, or
    /// a Git state the summary has not seen (`refreshGit`), restarts the
    /// wait. This and the panel's button are the only ways a summary is
    /// written: a panel that opens shows the stored one, and a command that
    /// finishes only restarts the wait, so the model never runs in the
    /// middle of work.
    func scheduleBackgroundSummary(_ projectID: UUID, after delay: Duration? = nil) {
        quietTimers[projectID]?.cancel()
        let wait = delay ?? summaryQuietPeriod
        quietTimers[projectID] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            quietTimers[projectID] = nil
            await writeSummary(projectID)
        }
    }

    /// Write a project's summary now. The git state is read fresh: the
    /// panel's cached one may be old, or absent when no panel was up.
    /// `force` writes it again for records that have one (the panel's
    /// button); otherwise the same records cost nothing.
    func writeSummary(_ projectID: UUID, force: Bool = false) async {
        guard summaryAllowed(), let project = projectLookup(projectID) else { return }
        if gitUnavailability(for: project) == nil {
            await apply(readGit(project), to: project)
        }
        guard !Task.isCancelled else { return }
        summarizer.refresh(
            projectID: projectID,
            digest: ProjectMemoryDigest(
                projectName: project.name,
                entries: store.entries(for: projectID),
                git: git[projectID],
                replyLanguage: OnDeviceModel.replyLanguage
            ),
            force: force
        )
    }

    /// Delete a project's memory, its cached git state and its summary.
    func forget(_ projectID: UUID) {
        quietTimers.removeValue(forKey: projectID)?.cancel()
        store.forget(projectID)
        git[projectID] = nil
        summarizer.forget(projectID: projectID)
    }

    func forgetAll() {
        for timer in quietTimers.values {
            timer.cancel()
        }
        quietTimers.removeAll()
        store.forgetAll()
        git.removeAll()
        summarizer.forgetAll()
    }

    /// Project lookup for the git read. Set by `attach`.
    @ObservationIgnored var projectLookup: (UUID) -> Project? = { _ in nil }

    /// Hand the feature the project list, and delete the memory of projects
    /// that were removed while Macterm was not running. A project list that
    /// did not load is not the user's: nothing is pruned against it, as the
    /// reapers skip a workspace file that did not load.
    func attach(projectStore: ProjectStore, panelShows: @escaping (UUID) -> Bool) {
        projectLookup = { [weak projectStore] id in projectStore?.projects.first { $0.id == id } }
        self.panelShows = panelShows
        guard Self.isSupported, !projectStore.loadFailed else { return }
        store.prune(keeping: Set(projectStore.projects.map(\.id)))
    }
}
