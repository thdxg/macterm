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
    static let rowCornerRadius: CGFloat = 14
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
        let actions = memory.suggestedActions(projectID: project.id, entries: entries)
        leftOff(summary)
        if !actions.isEmpty {
            section(String(localized: "Suggested")) {
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        ForEach(actions) { action in
                            actionRow(action)
                        }
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
        VStack(alignment: .leading, spacing: 8) {
            // The header row carries the reload button, so the body is the
            // paragraph alone.
            HStack(alignment: .firstTextBaseline) {
                Text("Summary")
                    .font(.headline)
                Spacer(minLength: 0)
                summaryButton
            }
            VStack(alignment: .leading, spacing: 10) {
                summaryParagraph
                if summary.lastActivity == nil {
                    Text("No commands recorded yet. Run something in this project.")
                        .font(.callout)
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                if let failure = summary.unresolvedFailure {
                    failureCard(failure)
                }
            }
        }
    }

    /// The model's paragraph, only where it can run, with the button that
    /// writes it again. With no summary yet, the button writes the first.
    @ViewBuilder
    private var summaryParagraph: some View {
        if summaryEnabled {
            let state = summarizer.state(for: project.id)
            switch state.phase {
            case .idle,
                 .failed:
                EmptyView()
            case .waiting where state.text.isEmpty:
                Text("Summarizing…")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
            case .waiting,
                 .streaming,
                 .done:
                // The model writes inline Markdown: backticks round commands
                // and files. Drawn, as Explain Output draws its reply.
                Text(ExplainPopoverView.rendered(state.text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var summaryEnabled: Bool {
        preferences.projectMemorySummary && ProjectMemorySummarizer.isEnabled && !entries.isEmpty
    }

    /// The reload button of the Summary header: a spinner while the model
    /// writes, else the button, which writes the first summary too.
    @ViewBuilder
    private var summaryButton: some View {
        if summaryEnabled {
            let state = summarizer.state(for: project.id)
            if state.phase == .waiting || state.phase == .streaming {
                ProgressView().controlSize(.mini)
            } else {
                let title = state.phase == .done ? String(localized: "Summarize Again") : String(localized: "Summarize")
                Button(title, systemImage: "arrow.clockwise") { writeSummary() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .help(title)
            }
        }
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
                        .font(action.kind == .frequent || action.kind == .suggested ? .callout.monospaced() : .callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = action.subtitle {
                        // A command's middle is its distinctive part; a
                        // sentence reads from its start.
                        Text(action.kind == .suggested ? ExplainPopoverView.rendered(subtitle) : AttributedString(subtitle))
                            .font(action.kind == .retry ? .caption.monospaced() : .caption)
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                            .truncationMode(action.kind == .retry ? .middle : .tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRow(cornerRadius: Self.rowCornerRadius)
        }
        .buttonStyle(.plain)
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
            if !git.branches.isEmpty {
                Text("Branches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .padding(.top, 4)
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        ForEach(git.branches, id: \.name) { branch in
                            branchRow(branch, isCurrent: branch.name == git.branch)
                        }
                    }
                }
            }
        }
    }

    /// A branch with its latest commit's age, as a glass row like the
    /// Suggested ones. The current branch is a row like the others, with the
    /// accent on its glass, the filled check and a bold name; one style for
    /// every row keeps the ages in line. A click switches to the branch: a
    /// tab in its worktree, as the sidebar's Worktrees menu opens (the
    /// current branch's worktree is the project itself), or `git switch`
    /// typed into a new split for a branch with no worktree, so the switch
    /// is on the screen and in the shell's history.
    private func branchRow(_ branch: GitStatus.Branch, isCurrent: Bool) -> some View {
        Button {
            switchTo(branch, isCurrent: isCurrent)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isCurrent ? MactermTheme.accent : MactermTheme.fgMuted)
                Text(verbatim: branch.name)
                    .font(.caption.monospaced().weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(branch.lastCommit.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRow(cornerRadius: Self.rowCornerRadius, tint: isCurrent ? MactermTheme.accent.opacity(0.35) : nil)
        }
        .buttonStyle(.plain)
        .help(branchHelp(branch, isCurrent: isCurrent))
    }

    private func switchTo(_ branch: GitStatus.Branch, isCurrent: Bool) {
        if let worktree = branch.worktree ?? (isCurrent ? project.path : nil) {
            ProjectMemoryActions.openTab(in: worktree, project: project, appState: appState, projects: projectStore.projects)
        } else {
            ProjectMemoryActions.run(
                command: "git switch \(branch.name)",
                directory: nil,
                in: project,
                appState: appState,
                projects: projectStore.projects
            )
        }
    }

    private func branchHelp(_ branch: GitStatus.Branch, isCurrent: Bool) -> String {
        if let worktree = branch.worktree ?? (isCurrent ? project.path : nil) {
            return String(localized: "Open a tab in the worktree at \(worktree)")
        }
        return String(localized: "Switch to \(branch.name) in a new split")
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

@available(macOS 26.0, *)
private extension View {
    /// A row of the panel as a glass button body: the button style's own
    /// glass ignores `buttonBorderShape`, so the row draws its glass itself,
    /// at the panel's row corner, with the press feedback of interactive
    /// glass.
    func glassRow(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
        return padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(glass.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}
