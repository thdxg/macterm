import Foundation

/// The palette's Worktrees: the active project's linked git worktrees — the
/// sidebar's Worktrees menu, searchable, minus the repository's main
/// worktree — each opening a tab of the project in its directory. A row is the worktree's branch (a short SHA for a
/// detached HEAD) over its path relative to the project root. The listing is
/// read from git's files each time the screen draws (`GitWorktrees.list`), so
/// it is never older than the keystroke.
@MainActor
final class WorktreesPaletteScope: PaletteScope {
    let list: @MainActor (String) -> [GitWorktree]

    let placeholder = "Search by branch or path..."

    init(list: @escaping @MainActor (String) -> [GitWorktree] = GitWorktrees.list(projectPath:)) {
        self.list = list
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        guard let projectID = context.appState.activeProjectID,
              let project = context.projectStore.projects.first(where: { $0.id == projectID })
        else { return [] }
        let worktrees = list(project.path).filter { !$0.isMain }
        guard !worktrees.isEmpty else {
            return [PaletteSection(header: nil, items: [
                PaletteItem(
                    id: "worktrees-none",
                    title: "No Other Worktrees",
                    subtitle: "Add one with git worktree add",
                    isEnabled: false,
                    action: {}
                ),
            ])]
        }

        // Empty, the listing's own order; searching, best match first with
        // that order breaking ties.
        let ranked = worktrees.compactMap { worktree -> PaletteItem? in
            let score = query.isEmpty ? 0 : Self.score(worktree, query: query.trimmed)
            return score.map { item(for: worktree, score: $0, in: project, context: context) }
        }
        .enumerated()
        .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
        .map(\.element)
        guard !ranked.isEmpty else { return [] }
        return [PaletteSection(header: nil, items: ranked)]
    }

    /// The row's title: what HEAD names.
    static func title(for worktree: GitWorktree) -> String {
        switch worktree.head {
        case let .branch(name): name
        case let .detached(sha): "\(sha.prefix(7)) (detached)"
        case nil: "Unknown HEAD"
        }
    }

    static func score(_ worktree: GitWorktree, query: String) -> Int? {
        [title(for: worktree), worktree.displayPath]
            .compactMap { fuzzyScore(query: query, target: $0) }
            .min()
    }

    private func item(for worktree: GitWorktree, score: Int, in project: Project, context: PaletteContext) -> PaletteItem {
        PaletteItem(
            id: "worktree:\(worktree.path)",
            title: Self.title(for: worktree),
            subtitle: worktree.displayPath,
            score: score
        ) { [appState = context.appState, projects = context.projectStore.projects] in
            appState.createTab(projectID: project.id, projects: projects, workingDirectory: worktree.path)
        }
    }
}
