import AppKit

/// Palette source for projects. Active search matches the name, then the path
/// (`Search`), and gives projects a small score boost over commands; empty state shows up to
/// 5 recently-visited projects (falling back to the store if recency is empty).
@MainActor
struct ProjectSource: PaletteSource {
    /// Wins a tie with a command: a project matched as well as a command is
    /// the one listed first. A stronger command match still beats it.
    private let projectBoost = 1

    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        let query = SearchQuery(query)
        return context.projectStore.projects.compactMap { project in
            guard let match = Search.match(query, fields: [project.name, project.path]) else { return nil }
            return makeItem(project: project, category: "Project", score: 0, context: context).with(match, boost: projectBoost)
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
