import Foundation

/// Tells the Project Insights panel that a local repository's git state may
/// have changed, at once, from anywhere: a `git switch` in a pane, an IDE, or
/// another terminal. Without it the panel learned of a switch only from a
/// command that Macterm recorded in the project, or from its 15 s read.
///
/// It watches the git directory of the project's repository and, for a
/// linked worktree, the common directory too: git writes `HEAD`, `index` and
/// `COMMIT_EDITMSG` through a lock file and a rename in the git dir, and a
/// branch's ref through the common dir, so every switch, commit, stage and
/// pull changes one of their entries. A directory watch (`.write`) fires
/// for a created, renamed or removed entry; it never reads a file. The panel
/// reads git with `GIT_OPTIONAL_LOCKS=0`, so its own reads write nothing
/// here and cannot wake it again.
///
/// The events are a hint, not a diff: the owner reads the state again, and
/// `ProjectMemory.refreshGit` replaces a read that waits, which debounces a
/// burst (a rebase writes hundreds of times).
final class GitDirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    /// Starts watching the git directories of the repository that holds
    /// `projectRoot` and calls `onChange` on the main queue for each change.
    /// nil when the folder is in no repository.
    init?(projectRoot: String, onChange: @escaping @MainActor () -> Void) {
        let directories = Self.directories(projectRoot: projectRoot)
        guard !directories.isEmpty else { return nil }
        for directory in directories {
            let fd = open(directory, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main
            )
            source.setEventHandler { MainActor.assumeIsolated { onChange() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        guard !sources.isEmpty else { return nil }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    /// The git dir, and the common dir when it is another one, of the
    /// repository that holds `projectRoot` (the folder itself or the nearest
    /// one above it with a `.git`). Empty when there is none.
    static func directories(projectRoot: String) -> [String] {
        var folder = (projectRoot as NSString).standardizingPath
        while true {
            if let gitDir = GitWorktrees.gitDir(atRoot: folder) {
                let common = GitWorktrees.commonDir(forGitDir: gitDir)
                return common == gitDir ? [gitDir] : [gitDir, common]
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, !parent.isEmpty else { return [] }
            folder = parent
        }
    }
}
