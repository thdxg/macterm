import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var sortOrder: Int
    var createdAt: Date

    init(name: String, path: String, sortOrder: Int = 0) {
        id = UUID()
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
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
