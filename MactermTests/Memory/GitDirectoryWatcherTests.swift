import Foundation
@testable import Macterm
import Testing

@MainActor
struct GitDirectoryWatcherTests {
    /// A folder tree in a temp directory: no git needed, the watcher reads
    /// only the metadata files that git leaves.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-gitwatch-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test
    func a_repository_root_and_a_folder_inside_it_watch_its_git_dir() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try mkdir(repo.appendingPathComponent(".git"))
        try mkdir(repo.appendingPathComponent("src/app"))
        let gitDir = repo.appendingPathComponent(".git").path
        #expect(GitDirectoryWatcher.directories(projectRoot: repo.path) == [gitDir])
        #expect(GitDirectoryWatcher.directories(projectRoot: repo.appendingPathComponent("src/app").path) == [gitDir])
    }

    @Test
    func a_linked_worktree_watches_its_own_git_dir_and_the_common_one() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("repo/.git")
        let admin = common.appendingPathComponent("worktrees/feature")
        try mkdir(admin)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("feature")
        try mkdir(worktree)
        try "gitdir: \(admin.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let dirs = GitDirectoryWatcher.directories(projectRoot: worktree.path)
        #expect(dirs.count == 2)
        #expect(dirs.first == admin.path)
        #expect(dirs.last.map { URL(fileURLWithPath: $0).standardized.path } == common.standardized.path)
    }

    @Test
    func a_folder_in_no_repository_watches_nothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GitDirectoryWatcher.directories(projectRoot: root.path).isEmpty)
        #expect(GitDirectoryWatcher(projectRoot: root.path) {} == nil)
    }

    @Test
    func a_switch_written_the_way_git_writes_it_is_seen() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git")
        try mkdir(gitDir)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: false, encoding: .utf8)
        var changes = 0
        let watcher = GitDirectoryWatcher(projectRoot: root.path) { changes += 1 }
        #expect(watcher != nil)
        // git writes HEAD.lock and renames it over HEAD.
        let lock = gitDir.appendingPathComponent("HEAD.lock")
        try "ref: refs/heads/feature\n".write(to: lock, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(gitDir.appendingPathComponent("HEAD"), withItemAt: lock)
        let deadline = Date().addingTimeInterval(2)
        while changes == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(changes > 0)
        withExtendedLifetime(watcher) {}
    }
}
