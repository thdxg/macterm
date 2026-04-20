import AppKit

/// Palette source for projects. Active search fuzzy-matches name + path and
/// gives projects a small score boost over commands; empty state shows up to
/// 5 recently-visited projects (falling back to the store if recency is empty).
@MainActor
struct ProjectSource: PaletteSource {
    /// Subtracted from each project's score so same-raw-score matches rank
    /// projects above commands. A very strong command match (score 0) still
    /// beats a weak project match.
    private let projectBoost = -1

    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        context.projectStore.projects.compactMap { project in
            let titleScore = fuzzyScore(query: query, target: project.name)
            let pathScore = fuzzyScore(query: query, target: project.path)
            guard let best = [titleScore, pathScore].compactMap(\.self).min() else { return nil }
            return makeItem(project: project, category: "Project", score: best + projectBoost, context: context)
        }
    }

    func emptyItems(context: PaletteContext) -> [PaletteItem]? {
        let recent = context.appState.recentProjects(
            from: context.projectStore.projects,
            limit: 10
        ).filter { $0.id != context.appState.activeProjectID }

        let pool = recent.isEmpty
            ? context.projectStore.projects.filter { $0.id != context.appState.activeProjectID }
            : recent

        let items = pool.prefix(5).map { makeItem(project: $0, category: "Recent", score: 0, context: context) }
        return items.isEmpty ? nil : Array(items)
    }

    private func makeItem(project: Project, category: String, score: Int, context: PaletteContext) -> PaletteItem {
        PaletteItem(
            id: "project:\(project.id.uuidString)",
            title: project.name,
            subtitle: project.path,
            category: category,
            score: score
        ) { [appState = context.appState] in
            appState.selectProject(project)
        }
    }
}
