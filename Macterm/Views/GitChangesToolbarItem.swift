import SwiftUI

/// The title-bar entry point for the repository-changes panel: a branch icon
/// that also PREVIEWS the active project's uncommitted work as `+adds −dels`,
/// so the window says whether there is anything to look at without the panel
/// being open. Clicking toggles the panel.
///
/// The preview is why this is its own view rather than a `Button` inline in
/// the toolbar builder: it needs state of its own (a debounced git read) that
/// must keep running while the panel is closed.
struct GitChangesToolbarItem: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    @State
    private var summary = GitChangeSummary()

    private var project: Project? {
        projectStore.projects.first { $0.id == appState.activeProjectID }
    }

    private var activeTabID: UUID? {
        guard let projectID = appState.activeProjectID else { return nil }
        return appState.workspaces[projectID]?.activeTabID
    }

    var body: some View {
        Button {
            appState.isGitChangesPanelVisible.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                if summary.hasChanges {
                    // Monospaced digits so the button doesn't reflow the
                    // toolbar every time a count ticks over a digit width.
                    HStack(spacing: 4) {
                        Text("+\(summary.additions)")
                            .foregroundStyle(MactermTheme.success)
                        Text("−\(summary.deletions)")
                            .foregroundStyle(MactermTheme.danger)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .help(summary.helpText)
        .foregroundStyle(appState.isGitChangesPanelVisible ? MactermTheme.accent : MactermTheme.fgMuted)
        .task(id: project?.id) {
            await summary.refresh(project: project, force: true)
        }
        // A tab switch usually means "show me the thing I was just working
        // on", so it is worth a forced read rather than a debounced one.
        .onChange(of: activeTabID) {
            Task { await summary.refresh(project: project, force: true) }
        }
        // Closing the panel is the other moment the count can be stale: the
        // panel refreshed itself while open and this view didn't.
        .onChange(of: appState.isGitChangesPanelVisible) { _, visible in
            if !visible {
                Task { await summary.refresh(project: project, force: true) }
            }
        }
        // Terminal activity is what actually changes a repository — a build, a
        // `git checkout`, an editor writing a file. The poll event fires far
        // too often to read git on each one (it bursts every 250ms while a
        // user types), so this coalesces; see `noteActivity`.
        .onReceive(NotificationCenter.default.publisher(for: .terminalPollEvent)) { _ in
            summary.noteActivity(project: project)
        }
    }
}

/// The counts behind the toolbar preview, kept deliberately small: this reads
/// git on a schedule driven by terminal activity, so everything here is about
/// NOT running git more often than a person can perceive.
@MainActor
@Observable
final class GitChangeSummary {
    private(set) var additions = 0
    private(set) var deletions = 0
    private(set) var fileCount = 0
    private(set) var isRepository = false

    /// Shortest gap between two actual git reads. Terminal activity can fire
    /// continuously (a build's output, a `tail -f`), and the counts are a
    /// glanceable hint, not a live cursor — a few seconds late is invisible,
    /// four subprocesses per keystroke is not.
    private static let minimumInterval: TimeInterval = 4
    /// How long to wait after the last activity before reading. A command
    /// writes its files as it finishes, so reading on the FIRST event of a
    /// burst would consistently measure the state before the change.
    private static let settleDelay: Duration = .milliseconds(1500)

    private var lastRead: Date = .distantPast
    private var pendingRead: Task<Void, Never>?
    /// Token of the most recently started read; see `refresh(project:force:)`.
    private var latestRequest = UUID()

    var hasChanges: Bool { isRepository && (additions > 0 || deletions > 0 || fileCount > 0) }

    var helpText: String {
        guard isRepository else { return "Repository Changes" }
        guard hasChanges else { return "Repository Changes — nothing uncommitted" }
        return fileCount == 1
            ? "Repository Changes — 1 file, +\(additions) −\(deletions)"
            : "Repository Changes — \(fileCount) files, +\(additions) −\(deletions)"
    }

    /// Coalesce a burst of terminal activity into at most one read. The first
    /// event arms a timer; later events during the wait are dropped, because
    /// the armed read will see their result too.
    func noteActivity(project: Project?) {
        guard pendingRead == nil else { return }
        pendingRead = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            await self?.refresh(project: project, force: false)
            self?.pendingRead = nil
        }
    }

    /// Read the counts. `force` skips the rate limit for the moments a user
    /// pointed at directly (opening a project, switching tabs, closing the
    /// panel); activity-driven reads leave it in place.
    func refresh(project: Project?, force: Bool) async {
        guard let project, !project.isRemote else {
            reset()
            return
        }
        if !force, Date().timeIntervalSince(lastRead) < Self.minimumInterval { return }
        lastRead = Date()
        // Two reads can be in flight at once (a forced one starting while a
        // debounced one waits on git), and they may be for DIFFERENT projects.
        // Only the newest may write, or switching projects can leave the older
        // repository's counts sitting beside the new project's name.
        let token = UUID()
        latestRequest = token
        let directory = ProjectPath.canonicalLocal(project.path)
        guard case .success = await GitClient.repository(at: directory) else {
            if latestRequest == token { reset() }
            return
        }
        let changes = await GitClient.changes(at: directory)
        guard latestRequest == token else { return }
        isRepository = true
        fileCount = changes.count
        additions = changes.reduce(0) { $0 + $1.additions }
        deletions = changes.reduce(0) { $0 + $1.deletions }
    }

    private func reset() {
        isRepository = false
        fileCount = 0
        additions = 0
        deletions = 0
    }
}
