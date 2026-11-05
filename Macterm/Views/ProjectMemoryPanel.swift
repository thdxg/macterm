import SwiftUI

/// The project memory panel: a floating Liquid Glass panel on the trailing
/// side of the window, over the terminal (the side sheet of Maps, mirrored).
/// It says where the user left off in the window's project, its git state,
/// and offers the next commands to run.
///
/// Everything here comes from `ProjectMemory`: the command log and the git
/// state, with no model. macOS 26 and later only, as the whole feature is.
@available(macOS 26.0, *)
struct ProjectMemoryPanel: View {
    let project: Project

    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @State
    private var preferences = Preferences.shared
    /// The sidebar's project icon (Settings → Appearance → Project icon), so
    /// the header shows the same glyph as the project's row.
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol: String

    static let width: CGFloat = 320
    static let inset: CGFloat = 10
    static let cornerRadius: CGFloat = 22
    static let recentLimit = 8
    /// How often the git state is read again while the panel is up and
    /// Macterm is active: a file saved in an editor inside a pane is no
    /// finished command.
    static let gitRefreshInterval: Duration = .seconds(15)

    private var memory: ProjectMemory { .shared }
    private var summarizer: ProjectMemorySummarizer { .shared }
    private var entries: [MemoryEntry] { memory.store.loadedEntries(for: project.id) }
    private var git: GitStatus? { memory.git[project.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if preferences.projectMemory {
                    content
                } else {
                    turnedOff
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: Self.cornerRadius)
        .padding(Self.inset)
        .task(id: project.id) {
            memory.store.prepare(project.id)
            // The stored summary, for the paragraph. Nothing is written
            // here: a summary is written after a quiet period, or by the
            // button.
            summarizer.prepare(projectID: project.id)
            // Git changes that no command in this project makes (another
            // app, an editor in a pane) show up with no button: the panel
            // reads the state while it is up, and the task ends with it.
            while !Task.isCancelled {
                if NSApp.isActive { memory.refreshGit(project.id) }
                try? await Task.sleep(for: Self.gitRefreshInterval)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from another app, where the user may have committed or
            // saved files.
            memory.refreshGit(project.id)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            projectIcon
            Text(verbatim: project.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// The project's row icon in the sidebar: the same symbol, number and
    /// color tag. Nothing when the setting is no icon.
    @ViewBuilder
    private var projectIcon: some View {
        if projectIconSymbol != Preferences.noIcon {
            let index = (projectStore.projects.firstIndex { $0.id == project.id } ?? 0) + 1
            if let color = project.color {
                TabRowIcon(symbol: projectIconSymbol, index: index)
                    .foregroundStyle(MactermTheme.color(for: color))
            } else {
                TabRowIcon(symbol: projectIconSymbol, index: index)
                    .foregroundStyle(MactermTheme.fgMuted)
            }
        }
    }

    // MARK: - Turned off

    private var turnedOff: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Project Memory Is Off"), systemImage: "brain")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn it on to see where you left off in each project and the commands to run next.")
                Text("Macterm records the commands that finish in your projects.")
                Text("It removes secrets first and keeps the records on this Mac only.")
            }
            .font(.callout)
            .foregroundStyle(MactermTheme.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Turn On Project Memory")) {
                preferences.projectMemory = true
            }
            .buttonStyle(.glassProminent)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let summary = ProjectMemorySummary(entries: entries)
        let actions = QuickActionRanker.actions(entries: entries, git: git)
        leftOff(summary)
        if !actions.isEmpty {
            section(String(localized: "Next")) {
                VStack(spacing: 6) {
                    ForEach(actions) { action in
                        actionRow(action)
                    }
                }
            }
        }
        gitSection
        if !entries.isEmpty {
            section(String(localized: "Recent")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries.suffix(Self.recentLimit).reversed()) { entry in
                        recentRow(entry)
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
            content()
        }
    }

    private func leftOff(_ summary: ProjectMemorySummary) -> some View {
        section(String(localized: "Summary")) {
            VStack(alignment: .leading, spacing: 10) {
                summaryParagraph
                if let last = summary.lastActivity {
                    Text("Last command \(last.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(MactermTheme.fgMuted)
                } else {
                    Text("No commands recorded yet. Run something in this project.")
                        .font(.callout)
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                if let failure = summary.unresolvedFailure {
                    failureCard(failure)
                } else if let last = summary.lastCommand, let command = last.command {
                    HStack(spacing: 6) {
                        outcomeGlyph(last.outcome)
                        Text(verbatim: command)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// The model's paragraph, only where it can run, with the button that
    /// writes it again. With no summary yet, the button writes the first.
    @ViewBuilder
    private var summaryParagraph: some View {
        if preferences.projectMemorySummary, ProjectMemorySummarizer.isEnabled, !entries.isEmpty {
            let state = summarizer.state(for: project.id)
            switch state.phase {
            case .idle,
                 .failed:
                summarizeButton(String(localized: "Summarize"))
            case .waiting where state.text.isEmpty:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Summarizing…")
                        .font(.callout)
                        .foregroundStyle(MactermTheme.fgMuted)
                }
            case .waiting,
                 .streaming,
                 .done:
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: state.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if state.phase == .done {
                        Button(String(localized: "Summarize Again"), systemImage: "arrow.clockwise") { writeSummary() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(MactermTheme.fgMuted)
                            .help(String(localized: "Summarize Again"))
                    }
                }
            }
        }
    }

    private func summarizeButton(_ title: String) -> some View {
        Button(title, systemImage: "sparkles") { writeSummary() }
            .buttonStyle(.glass)
            .help(String(localized: "Write a summary of where you left off with Apple Intelligence"))
    }

    private func writeSummary() {
        Task { await memory.writeSummary(project.id, force: true) }
    }

    private func failureCard(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                outcomeGlyph(.failure)
                Text(verbatim: entry.command ?? "")
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let code = entry.exitCode {
                Text("Failed with exit code \(code)")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.failure)
            }
            if let tail = entry.failureTail {
                Text(verbatim: tail)
                    .font(.caption.monospaced())
                    .foregroundStyle(MactermTheme.fgMuted)
                    .lineLimit(6)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MactermTheme.failure.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private func actionRow(_ action: QuickAction) -> some View {
        Button {
            ProjectMemoryActions.run(action, in: project, appState: appState, projects: projectStore.projects)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: action.title)
                        .font(action.kind == .frequent ? .callout.monospaced() : .callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = action.subtitle {
                        Text(verbatim: subtitle)
                            .font(action.kind == .retry ? .caption.monospaced() : .caption)
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glass)
        .help(action.command)
    }

    // MARK: - Git

    private var gitSection: some View {
        section(String(localized: "Git")) {
            if project.isRemote {
                Text("Git status is not available for remote projects yet.")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
            } else if let git {
                gitDetails(git)
            } else if memory.readingGit.contains(project.id) {
                ProgressView().controlSize(.small)
            } else {
                Text("This folder is not in a Git repository, or Git is not installed.")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
            }
        }
    }

    private func gitDetails(_ git: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(verbatim: git.branch ?? git.detachedAt.map { "(\($0))" } ?? "—")
                    .font(.callout.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if git.ahead > 0 { countLabel(git.ahead, symbol: "arrow.up") }
                if git.behind > 0 { countLabel(git.behind, symbol: "arrow.down") }
            }
            Text(gitHeadline(git))
                .font(.caption)
                .foregroundStyle(MactermTheme.fgMuted)
            ForEach(git.recentCommits, id: \.hash) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: commit.subject)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(commit.date.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(MactermTheme.fgDim)
                        .lineLimit(1)
                }
            }
            if git.branches.contains(where: { $0.name != git.branch }) {
                Text("Branches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .padding(.top, 4)
                ForEach(git.branches, id: \.name) { branch in
                    branchRow(branch, isCurrent: branch.name == git.branch)
                }
            }
        }
    }

    /// A branch with its latest commit's age and, when a worktree has it
    /// checked out, that worktree's folder. A click on such a branch opens a
    /// shell in the worktree; the panel never switches a branch.
    private func branchRow(_ branch: GitStatus.Branch, isCurrent: Bool) -> some View {
        Button {
            guard let worktree = branch.worktree else { return }
            ProjectMemoryActions.openShell(in: worktree, project: project, appState: appState, projects: projectStore.projects)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isCurrent ? MactermTheme.accent : MactermTheme.fgDim)
                Text(verbatim: branch.name)
                    .font(.caption.monospaced().weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let worktree = branch.worktree {
                    Label {
                        Text(verbatim: (worktree as NSString).lastPathComponent)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.caption2)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(branch.lastCommit.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(MactermTheme.fgDim)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(branch.worktree == nil)
        .help(branch.worktree.map { String(localized: "Open a shell in the worktree at \($0)") } ?? branch.subject)
    }

    private func countLabel(_ count: Int, symbol: String) -> some View {
        Label {
            Text(verbatim: "\(count)")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
    }

    private func gitHeadline(_ git: GitStatus) -> String {
        var parts: [String] = []
        if git.isClean { parts.append(String(localized: "No changes")) }
        if git.staged > 0 { parts.append(String(localized: "\(git.staged) staged")) }
        if git.unstaged > 0 { parts.append(String(localized: "\(git.unstaged) modified")) }
        if git.untracked > 0 { parts.append(String(localized: "\(git.untracked) untracked")) }
        if git.conflicted > 0 { parts.append(String(localized: "\(git.conflicted) conflicted")) }
        if git.stashes > 0 { parts.append(String(localized: "\(git.stashes) stashed")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Recent

    private func recentRow(_ entry: MemoryEntry) -> some View {
        Button {
            guard let command = entry.command else { return }
            ProjectMemoryActions.run(
                command: command,
                directory: entry.directory,
                in: project,
                appState: appState,
                projects: projectStore.projects
            )
        } label: {
            HStack(spacing: 6) {
                outcomeGlyph(entry.outcome)
                Text(verbatim: entry.command ?? String(localized: "Unknown command"))
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.command == nil ? MactermTheme.fgDim : MactermTheme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(entry.finishedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(MactermTheme.fgDim)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(entry.command == nil || entry.command.map(QuickActionRanker.isMasked) == true)
        .help(recentHelp(entry))
    }

    private func recentHelp(_ entry: MemoryEntry) -> String {
        guard let command = entry.command else { return "" }
        if QuickActionRanker.isMasked(command) {
            return String(localized: "This command had a secret. Macterm cannot run it again.")
        }
        return String(localized: "Run \(command) again in a new split")
    }

    @ViewBuilder
    private func outcomeGlyph(_ outcome: MemoryEntry.Outcome) -> some View {
        switch outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(MactermTheme.success)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(MactermTheme.failure)
        case .unknown:
            Image(systemName: "circle").foregroundStyle(MactermTheme.fgDim)
        }
    }
}
