import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// The optional project folder. A nil path groups tabs without a folder.
    /// Terminal creation uses `defaultDirectory` instead of inventing a path.
    var path: String?
    var sortOrder: Int
    var createdAt: Date
    /// Optional absolute path to zmx on a remote host (#104). When set, the
    /// remote spawn/kill/probe commands invoke it verbatim instead of
    /// resolving `zmx` through PATH — the deterministic escape hatch for hosts
    /// where PATH resolution fails (network-homed dirs, an exotic `/bin/sh`,
    /// PATH configured only in a non-POSIX shell). nil = PATH lookup. Ignored
    /// for local projects. Decodes as nil from older projects.json (absent
    /// key), so it's back-compatible.
    var zmxPath: String?
    /// Color tag — the `rawValue` of a `ProjectColor`. A String, not the enum,
    /// so an unknown value (hand-edited json, newer build) reads as untagged
    /// instead of failing the row's decode. Absent in older projects.json.
    var colorName: String?

    init(
        name: String,
        path: String? = nil,
        sortOrder: Int = 0,
        zmxPath: String? = nil,
        colorName: String? = nil
    ) {
        id = UUID()
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.zmxPath = zmxPath
        self.colorName = colorName
        createdAt = Date()
    }

    /// Keep an explicit ID for synthetic projects and imported layouts that
    /// have no folder. A folderless layout uses this ID to match its project.
    init(id: UUID, name: String, path: String?) {
        self.id = id
        self.name = name
        self.path = path
        sortOrder = 0
        zmxPath = nil
        colorName = nil
        createdAt = Date()
    }
}

extension Project {
    /// New terminals and relative layout paths start here. This fallback is
    /// not a project folder and must not identify a saved layout.
    var defaultDirectory: String { path ?? ProjectPath.currentHome }

    var pathLabel: String { path ?? String(localized: "No folder") }

    /// The slug of the zmx sessions that a new terminal of this project
    /// gets. nil keeps the default: the last component of the terminal's
    /// directory. A project without a folder takes its name, because
    /// `defaultDirectory` would give every such project, the pinned tabs and
    /// a project in the home folder one slug: the user name.
    var sessionSlug: String? {
        path == nil ? ZmxSessionName.slug(name) : nil
    }

    /// nil when untagged, or tagged with a value this build doesn't know.
    var color: ProjectColor? { colorName.flatMap(ProjectColor.init(rawValue:)) }

    /// Parsed location: `.local` for a directory path, `.remote` for an
    /// scp-style `[user@]host:dir` spec (#104). nil when `path` parses as
    /// neither or the project has no folder.
    var location: ProjectPath? { path.flatMap(ProjectPath.parse) }

    /// Whether this project lives on a remote host. Remote projects spawn
    /// panes over ssh (`RemoteSpawn`) and skip every local-cwd/local-pid
    /// feature (foreground poll, replace-path-with-cwd, live layout capture).
    var isRemote: Bool { path.map(ProjectPath.isRemote) ?? false }
}
