import Foundation
@testable import Macterm
import Testing

/// `GitWorktrees` reads git's metadata files instead of running git, so it is
/// held to what git itself says: repositories built with the real
/// `git worktree add` are compared against `git worktree list --porcelain`,
/// and the layouts git only builds on request (a relative gitdir, a bare
/// repository, a submodule, a prunable entry) are written by hand.
struct GitWorktreesTests {
    // MARK: - Against git

    @Test(.enabled(if: Git.isAvailable))
    func lists_what_git_lists_except_the_project_root() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = try Git.makeRepository(at: scratch.path("repo"))
        try Git.run(["worktree", "add", "-q", "-b", "feature", "../repo-feature"], in: repo)
        try Git.run(["worktree", "add", "-q", "-b", "nested", ".worktrees/nested"], in: repo)
        try Git.run(["worktree", "add", "-q", "--detach", "../repo-detached"], in: repo)

        let worktrees = GitWorktrees.list(projectRoot: repo)

        #expect(try describe(worktrees) == describe(Git.worktreeList(in: repo), excluding: repo))
        #expect(worktrees.map(\.displayPath) == ["../repo-detached", "../repo-feature", ".worktrees/nested"])
        #expect(worktrees.map(\.title).dropFirst() == ["../repo-feature — feature", ".worktrees/nested — nested"])
        #expect(worktrees.allSatisfy { !$0.isMain })
    }

    @Test(.enabled(if: Git.isAvailable))
    func a_linked_worktree_lists_the_main_worktree_first() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = try Git.makeRepository(at: scratch.path("repo"))
        try Git.run(["worktree", "add", "-q", "-b", "feature", "../repo-feature"], in: repo)
        try Git.run(["worktree", "add", "-q", "-b", "other", "../repo-other"], in: repo)
        let feature = scratch.path("repo-feature")

        let worktrees = GitWorktrees.list(projectRoot: feature)

        #expect(try describe(worktrees) == describe(Git.worktreeList(in: feature), excluding: feature))
        #expect(worktrees.map(\.title) == ["../repo — main", "../repo-other — other"])
        #expect(worktrees.map(\.isMain) == [true, false])
    }

    @Test(.enabled(if: Git.isAvailable))
    func relative_worktree_paths_match_git() throws {
        // `worktree.useRelativePaths` is git 2.48+; an older git ignores the
        // key and writes absolute paths, which must match just the same.
        let scratch = try Scratch()
        defer { scratch.remove() }
        let repo = try Git.makeRepository(at: scratch.path("repo"))
        try Git.run(["-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", "-b", "rel", "../repo-rel"], in: repo)
        let linked = scratch.path("repo-rel")

        #expect(try describe(GitWorktrees.list(projectRoot: repo)) == describe(Git.worktreeList(in: repo), excluding: repo))
        #expect(try describe(GitWorktrees.list(projectRoot: linked)) == describe(Git.worktreeList(in: linked), excluding: linked))
    }

    // MARK: - Hand-built layouts

    @Test
    func relative_gitdir_paths_resolve_against_their_own_directories() throws {
        // What git ≥ 2.48 writes under `worktree.useRelativePaths`: the
        // worktree's `.git` file is relative to the worktree, and the admin
        // folder's `gitdir` to the admin folder.
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("main/.git")
        try scratch.write("main/.git/worktrees/feature/HEAD", "ref: refs/heads/feature\n")
        try scratch.write("main/.git/worktrees/feature/commondir", "../..\n")
        try scratch.write("main/.git/worktrees/feature/gitdir", "../../../../feature/.git\n")
        try scratch.write("feature/.git", "gitdir: ../main/.git/worktrees/feature\n")

        #expect(GitWorktrees.list(projectRoot: scratch.path("main")).map(\.title) == ["../feature — feature"])
        #expect(GitWorktrees.list(projectRoot: scratch.path("feature")).map(\.title) == ["../main — main"])
    }

    @Test
    func a_project_that_is_a_linked_worktree_lists_main_then_its_siblings() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")
        try scratch.addWorktree("wt/b", id: "b", commonDir: "repo/.git", head: "ref: refs/heads/b")
        try scratch.addWorktree("wt/a", id: "a", commonDir: "repo/.git", head: "ref: refs/heads/a")
        try scratch.addWorktree("wt/c", id: "c", commonDir: "repo/.git", head: "ref: refs/heads/topic/c")

        let worktrees = GitWorktrees.list(projectRoot: scratch.path("wt/b"))

        #expect(worktrees.map(\.title) == ["../../repo — main", "../a — a", "../c — topic/c"])
        #expect(worktrees.map(\.isMain) == [true, false, false])
        #expect(worktrees.first?.path == scratch.path("repo"))
        #expect(worktrees.last?.path == scratch.path("wt/c"))
    }

    @Test
    func a_detached_head_shows_a_short_sha() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sha = "0123456789abcdef0123456789abcdef01234567"
        try scratch.writeGitDir("repo/.git")
        try scratch.addWorktree("detached", id: "detached", commonDir: "repo/.git", head: sha)

        let worktree = try #require(GitWorktrees.list(projectRoot: scratch.path("repo")).first)

        #expect(worktree.head == .detached(sha))
        #expect(worktree.title == "../detached — 0123456")
    }

    @Test
    func prunable_entries_are_skipped() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")
        try scratch.addWorktree("kept", id: "kept", commonDir: "repo/.git", head: "ref: refs/heads/kept")
        // The worktree directory was deleted without `git worktree remove`.
        try scratch.addWorktree("deleted", id: "deleted", commonDir: "repo/.git", head: "ref: refs/heads/deleted")
        try FileManager.default.removeItem(atPath: scratch.path("deleted"))
        // An admin folder with no `gitdir` file at all.
        try scratch.write("repo/.git/worktrees/broken/HEAD", "ref: refs/heads/broken\n")

        #expect(GitWorktrees.list(projectRoot: scratch.path("repo")).map(\.title) == ["../kept — kept"])
    }

    @Test
    func a_bare_repository_has_no_main_worktree() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo.git", config: "[core]\n\tbare = true\n")
        try scratch.addWorktree("main", id: "main", commonDir: "repo.git", head: "ref: refs/heads/main")
        try scratch.addWorktree("feature", id: "feature", commonDir: "repo.git", head: "ref: refs/heads/feature")

        #expect(GitWorktrees.list(projectRoot: scratch.path("main")).map(\.title) == ["../feature — feature"])
    }

    /// The "bare repository in `.git`" layout is the one where bare-ness is
    /// all that stops the container directory — the parent of a common dir
    /// named `.git` — from being listed as the main worktree.
    @Test(arguments: [
        BareConfig(config: "[core]\n\tbare = true\n"),
        BareConfig(config: "[core]\n\tbare\n"),
        BareConfig(config: "[Core]\n\tBare = YES # set by git clone --bare\n"),
        BareConfig(config: "[core] bare = 1\n"),
        BareConfig(config: "[core]\n\tbare = \"true\"\n"),
        BareConfig(
            config: "[core]\n\tbare = false\n[extensions]\n\tworktreeConfig = true\n",
            configWorktree: "[core]\n\tbare = true\n"
        ),
    ])
    func bare_is_read_the_way_git_writes_it(_ bare: BareConfig) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("container/.git", config: bare.config)
        if let configWorktree = bare.configWorktree {
            try scratch.write("container/.git/config.worktree", configWorktree)
        }
        try scratch.addWorktree("container/main", id: "main", commonDir: "container/.git", head: "ref: refs/heads/main")
        try scratch.addWorktree("container/feature", id: "feature", commonDir: "container/.git", head: "ref: refs/heads/feature")

        #expect(GitWorktrees.list(projectRoot: scratch.path("container/main")).map(\.title) == ["../feature — feature"])
        // The container is the project root here, so both worktrees show.
        #expect(GitWorktrees.list(projectRoot: scratch.path("container")).map(\.title) == ["feature — feature", "main — main"])
    }

    @Test(arguments: [
        "[core]\n\tbare = false\n",
        "[core]\n\t# bare = true\n",
        "[remote \"origin\"]\n\tbare = true\n",
        "[core.sub]\n\tbare = true\n",
        "[core]\n\tbare = true\n[extensions]\n\tworktreeConfig = true\n",
    ])
    func a_non_bare_repository_lists_its_main_worktree(_ config: String) throws {
        // The last one: under `extensions.worktreeConfig`, `config.worktree`
        // (written here) is read after `config` and wins.
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git", config: config)
        if config.contains("worktreeConfig") {
            try scratch.write("repo/.git/config.worktree", "[core]\n\tbare = false\n")
        }
        try scratch.addWorktree("feature", id: "feature", commonDir: "repo/.git", head: "ref: refs/heads/feature")

        #expect(GitWorktrees.list(projectRoot: scratch.path("feature")).map(\.title) == ["../repo — main"])
    }

    @Test
    func a_submodules_main_worktree_is_its_core_worktree() throws {
        // `git submodule add` keeps the submodule's git dir in the
        // superproject's `.git/modules/` and points `core.worktree` back at
        // the checkout. The parent of that git dir is no worktree at all.
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir(
            "super/.git/modules/sub",
            config: "[core]\n\tbare = false\n\tworktree = ../../../sub\n"
        )
        try scratch.write("super/sub/.git", "gitdir: ../.git/modules/sub\n")
        try scratch.addWorktree("sub-wt", id: "sub-wt", commonDir: "super/.git/modules/sub", head: "ref: refs/heads/subfeat")

        #expect(GitWorktrees.list(projectRoot: scratch.path("super/sub")).map(\.title) == ["../../sub-wt — subfeat"])
        let fromLinked = GitWorktrees.list(projectRoot: scratch.path("sub-wt"))
        #expect(fromLinked.map(\.title) == ["../super/sub — main"])
        #expect(fromLinked.first?.isMain == true)
    }

    @Test
    func a_separate_git_dir_lists_no_main_worktree() throws {
        // `git init --separate-git-dir` records nothing that leads from the
        // git dir back to its main worktree; git lists the git dir itself
        // there, which is no directory to open a shell in.
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo.git")
        try scratch.write("work/.git", "gitdir: \(scratch.path("repo.git"))\n")
        try scratch.addWorktree("feature", id: "feature", commonDir: "repo.git", head: "ref: refs/heads/feature")

        #expect(GitWorktrees.list(projectRoot: scratch.path("work")).map(\.title) == ["../feature — feature"])
        #expect(GitWorktrees.list(projectRoot: scratch.path("feature")).isEmpty)
    }

    @Test
    func a_root_reached_through_a_symlink_is_recognized() throws {
        // Git records resolved paths (`/private/tmp/…`); a project added as
        // `/tmp/…` must still see itself in them, and measure from there.
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("real/repo/.git")
        try scratch.addWorktree("real/repo-feature", id: "feature", commonDir: "real/repo/.git", head: "ref: refs/heads/feature")
        try scratch.addWorktree("real/repo-other", id: "other", commonDir: "real/repo/.git", head: "ref: refs/heads/other")
        try FileManager.default.createSymbolicLink(atPath: scratch.path("link"), withDestinationPath: scratch.path("real"))

        #expect(GitWorktrees.list(projectRoot: scratch.path("link/repo-feature")).map(\.title) == [
            "../repo — main", "../repo-other — other",
        ])
    }

    @Test
    func worktrees_after_the_main_one_are_in_finder_order() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")
        for name in ["repo/.worktrees/a", "wt10", "wt2", "Wt3"] {
            try scratch.addWorktree(name, id: (name as NSString).lastPathComponent, commonDir: "repo/.git", head: "ref: refs/heads/x")
        }
        try scratch.addWorktree("from", id: "from", commonDir: "repo/.git", head: "ref: refs/heads/from")

        #expect(GitWorktrees.list(projectRoot: scratch.path("from")).map(\.displayPath) == [
            "../repo", "../repo/.worktrees/a", "../wt2", "../Wt3", "../wt10",
        ])
    }

    @Test
    func a_directory_that_is_not_a_repositorys_top_has_no_worktrees() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")
        try scratch.addWorktree("feature", id: "feature", commonDir: "repo/.git", head: "ref: refs/heads/feature")
        try FileManager.default.createDirectory(atPath: scratch.path("repo/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: scratch.path("plain"), withIntermediateDirectories: true)
        try scratch.write("garbage/.git", "not a gitfile\n")
        try scratch.write("dangling/.git", "gitdir: ../nowhere/.git\n")

        // Only the root counts: a subdirectory of a repository is not one.
        #expect(GitWorktrees.list(projectRoot: scratch.path("repo/sub")).isEmpty)
        #expect(GitWorktrees.list(projectRoot: scratch.path("plain")).isEmpty)
        #expect(GitWorktrees.list(projectRoot: scratch.path("garbage")).isEmpty)
        #expect(GitWorktrees.list(projectRoot: scratch.path("dangling")).isEmpty)
        #expect(GitWorktrees.list(projectRoot: scratch.path("missing")).isEmpty)
    }

    @Test
    func a_repository_without_other_worktrees_lists_none() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")

        #expect(GitWorktrees.list(projectRoot: scratch.path("repo")).isEmpty)
    }

    @Test
    func a_remote_project_lists_none() {
        #expect(GitWorktrees.list(projectPath: "devbox:~/repo").isEmpty)
        #expect(GitWorktrees.list(projectPath: "deploy@10.0.0.5:/srv/app").isEmpty)
        #expect(GitWorktrees.list(projectPath: "").isEmpty)
    }

    @Test
    func a_local_project_path_is_canonicalized_first() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.writeGitDir("repo/.git")
        try scratch.addWorktree("feature", id: "feature", commonDir: "repo/.git", head: "ref: refs/heads/feature")

        #expect(GitWorktrees.list(projectPath: scratch.path("repo") + "/").map(\.title) == ["../feature — feature"])
    }

    // MARK: - Presentation

    @Test
    func relative_paths_climb_to_the_deepest_shared_directory() {
        #expect(GitWorktrees.relativePath(from: "/a/repo", to: "/a/repo-feature") == "../repo-feature")
        #expect(GitWorktrees.relativePath(from: "/a/repo", to: "/a/repo/.worktrees/foo") == ".worktrees/foo")
        #expect(GitWorktrees.relativePath(from: "/a/repo/.claude/worktrees/x", to: "/a/repo") == "../../..")
        #expect(GitWorktrees.relativePath(from: "/a/repo/wt", to: "/a/repo") == "..")
        #expect(GitWorktrees.relativePath(from: "/a/repo", to: "/a/repo") == ".")
        // Sharing only `/`, a relative path is no clearer than the absolute one.
        #expect(GitWorktrees.relativePath(from: "/Users/me/repo", to: "/Volumes/Disk/wt") == nil)
    }

    @Test
    func titles_pair_the_path_with_the_branch_or_a_short_sha() {
        func title(_ head: GitWorktree.Head?) -> String {
            GitWorktree(path: "/a/x", displayPath: "../x", head: head, isMain: false).title
        }
        #expect(title(.branch("feature/login")) == "../x — feature/login")
        #expect(title(.detached("abcdef0123456789abcdef0123456789abcdef01")) == "../x — abcdef0")
        #expect(title(nil) == "../x")
    }

    // MARK: - Helpers

    struct BareConfig: CustomTestStringConvertible {
        let config: String
        var configWorktree: String?

        var testDescription: String {
            configWorktree.map { "\(config.debugDescription) + config.worktree \($0.debugDescription)" }
                ?? config.debugDescription
        }
    }

    /// Worktrees as comparable lines — resolved path, then HEAD — so the
    /// listing and git's own can be compared whatever order they're in.
    private func describe(_ worktrees: [GitWorktree]) -> [String] {
        worktrees.map { line(path: $0.path, head: $0.head) }.sorted()
    }

    private func describe(_ listed: [Git.Listed], excluding root: String) -> [String] {
        listed.map { line(path: $0.path, head: $0.head) }
            .filter { !$0.hasPrefix(resolved(root) + " ") }
            .sorted()
    }

    private func line(path: String, head: GitWorktree.Head?) -> String {
        "\(resolved(path)) \(head.map(String.init(describing:)) ?? "-")"
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// A throwaway directory for one test's repositories.
private struct Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A git dir's own files: a HEAD on `main` and a config.
    func writeGitDir(_ relative: String, config: String = "[core]\n\tbare = false\n") throws {
        try write(relative + "/HEAD", "ref: refs/heads/main\n")
        try write(relative + "/config", config)
    }

    /// What `git worktree add` leaves behind: the admin folder under the
    /// common dir, with absolute paths, and the worktree's `.git` file.
    func addWorktree(_ worktree: String, id: String, commonDir: String, head: String) throws {
        let admin = commonDir + "/worktrees/" + id
        try write(admin + "/HEAD", head + "\n")
        try write(admin + "/commondir", "../..\n")
        try write(admin + "/gitdir", path(worktree + "/.git") + "\n")
        try write(worktree + "/.git", "gitdir: \(path(admin))\n")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The real git, run in an environment of its own: no global or system
/// config and no inherited `GIT_*` variables, so neither the developer's setup
/// nor a surrounding repository reaches the fixture.
private enum Git {
    struct Listed {
        let path: String
        let head: GitWorktree.Head?
    }

    static let executable: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/git" } + ["/usr/bin/git", "/opt/homebrew/bin/git"]
        guard let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let url = URL(fileURLWithPath: found)
        return (try? run(["--version"], in: NSTemporaryDirectory(), executable: url)) == nil ? nil : url
    }()

    static var isAvailable: Bool {
        executable != nil
    }

    /// A repository with one empty commit on `main`.
    static func makeRepository(at path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try run(["init", "-q"], in: path)
        try run(["commit", "-q", "--allow-empty", "-m", "initial"], in: path)
        return path
    }

    /// `git worktree list --porcelain`, minus the entries the menu can't
    /// open: a bare repository's own entry and prunable ones.
    static func worktreeList(in directory: String) throws -> [Listed] {
        try run(["worktree", "list", "--porcelain"], in: directory)
            .components(separatedBy: "\n\n")
            .compactMap { record in
                let lines = record.split(separator: "\n").map(String.init)
                func value(_ key: String) -> String? {
                    lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) }
                }
                guard let path = value("worktree"),
                      !lines.contains("bare"),
                      !lines.contains(where: { $0.hasPrefix("prunable") })
                else { return nil }
                let head: GitWorktree.Head? = if let branch = value("branch") {
                    .branch(branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch)
                } else {
                    value("HEAD").map(GitWorktree.Head.detached)
                }
                return Listed(path: path, head: head)
            }
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: String) throws -> String {
        guard let executable else { throw GitError(message: "git is not installed") }
        return try run(arguments, in: directory, executable: executable)
    }

    private static func run(_ arguments: [String], in directory: String, executable: URL) throws -> String {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for role in ["AUTHOR", "COMMITTER"] {
            environment["GIT_\(role)_NAME"] = "Macterm Tests"
            environment["GIT_\(role)_EMAIL"] = "tests@macterm.invalid"
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(arguments.joined(separator: " ")): \(String(decoding: errorData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct GitError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
