import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
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
        path: String,
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

    /// Explicit-id variant for SYNTHETIC projects only (`PinnedTabs.project`).
    /// Real projects always mint a fresh id above — a directory is not an
    /// identity, and two projects may share a path.
    init(id: UUID, name: String, path: String) {
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
    /// nil when untagged, or tagged with a value this build doesn't know.
    var color: ProjectColor? { colorName.flatMap(ProjectColor.init(rawValue:)) }

    /// Parsed location: `.local` for a directory path, `.remote` for an
    /// scp-style `[user@]host:dir` spec (#104). nil when `path` parses as
    /// neither (a hand-corrupted projects.json entry).
    var location: ProjectPath? { ProjectPath.parse(path) }

    /// Whether this project lives on a remote host. Remote projects spawn
    /// panes over ssh (`RemoteSpawn`) and skip every local-cwd/local-pid
    /// feature (foreground poll, replace-path-with-cwd, live layout capture).
    var isRemote: Bool { ProjectPath.isRemote(path) }
}
