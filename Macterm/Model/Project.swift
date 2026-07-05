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

    init(name: String, path: String, sortOrder: Int = 0, zmxPath: String? = nil) {
        id = UUID()
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        self.zmxPath = zmxPath
        createdAt = Date()
    }
}

extension Project {
    /// Parsed location: `.local` for a directory path, `.remote` for an
    /// scp-style `[user@]host:dir` spec (#104). nil when `path` parses as
    /// neither (a hand-corrupted projects.json entry).
    var location: ProjectPath? { ProjectPath.parse(path) }

    /// Whether this project lives on a remote host. Remote projects spawn
    /// panes over ssh (`RemoteSpawn`) and skip every local-cwd/local-pid
    /// feature (foreground poll, replace-path-with-cwd, live layout capture).
    var isRemote: Bool { ProjectPath.isRemote(path) }
}
