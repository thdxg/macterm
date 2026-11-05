import AppIntents
import AppKit
import CoreSpotlight
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

/// Projects are in Spotlight (`ProjectSpotlightIndex`). A click on a result
/// runs `OpenMactermProjectIntent`.
@available(macOS 15.0, *)
extension MactermProjectEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.displayName = name
        set.contentDescription = path
        // The folder's own name finds a project that the user renamed.
        set.keywords = [name, (path as NSString).lastPathComponent]
        return set
    }
}

struct MactermProjectQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func all() async throws -> [MactermProjectEntity] {
        let ctx = try await MactermIntentHost.shared.context()
        // The pinned and the scratch workspaces are offered only once they
        // exist — before that there is nothing to address in them.
        let pinned = ctx.appState.workspaces[PinnedTabs.projectID] != nil
            ? [MactermProjectEntity(PinnedTabs.project)]
            : []
        let scratch = ctx.appState.hasScratchTabs ? [MactermProjectEntity(ScratchTabs.project)] : []
        return pinned + ctx.projectStore.projects.map(MactermProjectEntity.init) + scratch
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [MactermProjectEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MactermProjectEntity] {
        // The app's one search (`Macterm/Search/`), ranked, as the palette's.
        try await Search.rank(all(), by: string) { [$0.name] }
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
        try await Search.rank(all(), by: string) { [$0.title] }
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

extension MactermPaneEntity {
    /// The identifier of the pane entity for a session.
    static func identifier(forSession session: String) -> EntityIdentifier {
        EntityIdentifier(for: MactermPaneEntity.self, identifier: session)
    }

    /// Tag a pane's terminal view with its pane entity, so that Siri and
    /// Apple Intelligence can resolve "this pane" to the pane on the screen.
    ///
    /// Only the identifier, never the pane's text: the entity does not adopt
    /// `Transferable`, because the system would read the text without the
    /// `macos-shortcuts` gate, and terminal text can hold secrets. Get Pane
    /// Contents stays the one way to read it. A mirror carries the same
    /// session, which `IntentTargets.pane` resolves to the leader.
    @MainActor
    static func annotate(_ view: NSView, for pane: Pane) {
        guard #available(macOS 15.4, *) else { return }
        view.appEntityIdentifier = IntentTargets.isAddressablePane(projectID: pane.projectID)
            ? identifier(forSession: pane.sessionName)
            : nil
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
        try await Search.rank(all(), by: string) { [$0.title, $0.id] }
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
