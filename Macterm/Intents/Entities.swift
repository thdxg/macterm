import AppIntents
import Foundation

// MARK: - Project

/// A project in the sidebar, as Shortcuts sees it.
///
/// Identity is `Project.id`, which `projects.json` persists — so a shortcut
/// written against a project still names it after a relaunch, a rename, or a
/// path change. The pinned workspace appears too, under its synthetic
/// project, because tab and pane actions work there like anywhere else.
struct MactermProjectEntity: AppEntity {
    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Path")
    var path: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Project")
    }

    static let defaultQuery = MactermProjectQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
    }

    @MainActor
    init(_ project: Project) {
        id = project.id
        name = project.name
        path = project.path
    }
}

struct MactermProjectQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func all() async throws -> [MactermProjectEntity] {
        let ctx = try await MactermIntentHost.shared.context()
        // The pinned workspace is offered only once it exists — before that
        // there is nothing to address in it.
        let pinned = ctx.appState.workspaces[PinnedTabs.projectID] != nil
            ? [MactermProjectEntity(PinnedTabs.project)]
            : []
        return pinned + ctx.projectStore.projects.map(MactermProjectEntity.init)
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [MactermProjectEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MactermProjectEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func allEntities() async throws -> [MactermProjectEntity] {
        try await all()
    }

    @MainActor
    func suggestedEntities() async throws -> [MactermProjectEntity] {
        try await all()
    }
}

// MARK: - Tab

/// A tab, as Shortcuts sees it. Identity is `TerminalTab.id`, which the
/// workspace snapshot persists, so a saved shortcut survives a relaunch.
struct MactermTabEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Project")
    var project: String?

    @Property(title: "Panes")
    var paneCount: Int

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tab")
    }

    static let defaultQuery = MactermTabQuery()

    var displayRepresentation: DisplayRepresentation {
        // The project is the subtitle because a tab title is usually just the
        // foreground process ("nu", "hx") and says nothing about where it is.
        DisplayRepresentation(title: "\(title)", subtitle: project.map { "\($0)" })
    }

    @MainActor
    init(_ tab: TerminalTab, projectID: UUID, in ctx: AppCommandContext) {
        id = tab.id
        title = tab.sidebarTitle
        project = IntentTargets.projectName(projectID, in: ctx)
        paneCount = tab.splitRoot.allPanes().count
    }
}

struct MactermTabQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func all() async throws -> [MactermTabEntity] {
        let ctx = try await MactermIntentHost.shared.context()
        return IntentTargets.allTabs(in: ctx).map { MactermTabEntity($0.tab, projectID: $0.projectID, in: ctx) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [MactermTabEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MactermTabEntity] {
        try await all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func allEntities() async throws -> [MactermTabEntity] {
        try await all()
    }

    @MainActor
    func suggestedEntities() async throws -> [MactermTabEntity] {
        try await all()
    }
}

// MARK: - Pane

/// A pane, as Shortcuts sees it.
///
/// **Identity is the zmx session name, not `Pane.id`.** Pane UUIDs are fresh
/// on every restore, so a shortcut keyed on one would break at the first
/// relaunch — silently, since the pane it names is visibly still there. The
/// session name is the restart-stable identity the whole app reattaches by,
/// and it is what the CLI's `--session` selector already addresses.
struct MactermPaneEntity: AppEntity {
    /// The pane's `sessionName`.
    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Project")
    var project: String?

    @Property(title: "Working Directory")
    var workingDirectory: String?

    @Property(title: "Foreground Process")
    var foregroundProcess: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Pane")
    }

    static let defaultQuery = MactermPaneQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: project.map { "\($0)" })
    }

    @MainActor
    init(_ pane: Pane, projectID: UUID, in ctx: AppCommandContext) {
        id = pane.sessionName
        title = pane.displayTitle
        project = IntentTargets.projectName(projectID, in: ctx)
        workingDirectory = pane.nsView?.currentPwd ?? pane.projectPath
        foregroundProcess = pane.foregroundProcessName
    }
}

struct MactermPaneQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func all() async throws -> [MactermPaneEntity] {
        let ctx = try await MactermIntentHost.shared.context()
        return IntentTargets.allPanes(in: ctx).map { MactermPaneEntity($0.pane, projectID: $0.projectID, in: ctx) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MactermPaneEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MactermPaneEntity] {
        // Both the visible title and the session name match: the title is what
        // the user reads in the sidebar, the session name is what a script
        // (or `$MACTERM_SESSION`) already has in hand.
        try await all().filter {
            $0.title.localizedCaseInsensitiveContains(string)
                || $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor
    func allEntities() async throws -> [MactermPaneEntity] {
        try await all()
    }

    @MainActor
    func suggestedEntities() async throws -> [MactermPaneEntity] {
        try await all()
    }
}
