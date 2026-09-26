import Foundation

/// One worktree of a project's git repository, as the sidebar's Worktrees
/// menu lists it.
struct GitWorktree: Equatable, Identifiable {
    /// What the worktree's HEAD names.
    enum Head: Equatable {
        /// A branch, without its `refs/heads/` prefix.
        case branch(String)
        /// A detached HEAD's full object name.
        case detached(String)
    }

    /// The worktree's directory — the working directory of a tab opened in
    /// it. Absolute, and standardized the way `ProjectPath.canonicalLocal`
    /// standardizes a project's own path: symlinks are not resolved.
    let path: String
    /// `path` relative to the project root (`../repo-feature`,
    /// `.worktrees/foo`, `..`) — or, when the two share nothing below `/`,
    /// the absolute path with the home directory contracted to `~`.
    let displayPath: String
    /// nil when the worktree's HEAD is missing or unreadable.
    let head: Head?
    /// The repository's main worktree (the one `git init` or `clone` made),
    /// as opposed to one added with `git worktree add`.
    let isMain: Bool

    var id: String { path }

    /// The menu line: "path — branch", with a short SHA for a detached HEAD
    /// (git's own default abbreviation length).
    var title: String {
        switch head {
        case let .branch(name): "\(displayPath) — \(name)"
        case let .detached(sha): "\(displayPath) — \(sha.prefix(7))"
        case nil: displayPath
        }
    }
}

/// A project's git worktrees, read from git's metadata files — never from
/// `git worktree list`. On a Mac without the Command Line Tools,
/// `/usr/bin/git` is a shim that pops the install dialog, and a context menu
/// must not wait on a process in any case. Everything `git worktree list`
/// prints is on disk:
///
/// - `<root>/.git` is the repository's git dir, or a file `gitdir: <path>`
///   naming it (relative to the root unless absolute) when the root is itself
///   a linked worktree, a submodule or a `--separate-git-dir` checkout.
/// - The common dir is the path in `<gitdir>/commondir` (relative to the
///   gitdir) when that file exists, else the gitdir itself.
/// - Each linked worktree has `<common>/worktrees/<id>/`. Its `gitdir` file
///   names the worktree's `.git` file — absolute, or relative to that folder
///   under git ≥ 2.48's `worktree.useRelativePaths` — and the worktree is
///   that file's directory. Its `HEAD` is the worktree's HEAD. A `.git` file
///   that no longer exists is git's "prunable", and is skipped.
/// - The main worktree's HEAD is `<common>/HEAD`. Its directory is
///   `core.worktree` when that is set (a submodule's is), else the parent of a
///   common dir named `.git`. A bare repository has no main worktree, and a
///   `--separate-git-dir` one never records where its main worktree is, so
///   neither lists one; git itself lists the git dir there, which is no place
///   to open a shell.
///
/// Only the project root is consulted: a project that is a subdirectory of a
/// repository, not its top, has no worktrees here.
enum GitWorktrees {
    /// The worktrees of the project at `projectPath` (a `Project.path`). A
    /// remote project has none: its files are only reachable over ssh, and a
    /// menu never starts one.
    static func list(projectPath: String) -> [GitWorktree] {
        guard case let .local(path)? = ProjectPath.parse(projectPath) else { return [] }
        return list(projectRoot: ProjectPath.canonicalLocal(path))
    }

    /// Every worktree of the repository at `projectRoot` except the root
    /// itself — the main worktree first, then the rest in Finder order of
    /// their display paths. Empty when the root is not a repository's top.
    /// Worktrees are compared by their symlink-resolved paths, so a root
    /// spelled `/tmp/…` is recognized in git's `/private/tmp/…`.
    static func list(projectRoot: String) -> [GitWorktree] {
        guard let gitDir = gitDir(atRoot: projectRoot) else { return [] }
        let commonDir = commonDir(forGitDir: gitDir)
        var recorded = linkedWorktrees(commonDir: commonDir)
        if let main = mainWorktreePath(commonDir: commonDir) {
            recorded.append(Recorded(path: main, head: head(at: commonDir + "/HEAD"), isMain: true))
        }

        let root = resolved(projectRoot)
        return recorded
            .compactMap { worktree -> GitWorktree? in
                let target = resolved(worktree.path)
                guard target != root else { return nil }
                return GitWorktree(
                    path: worktree.path,
                    displayPath: relativePath(from: root, to: target) ?? ProjectPath.homeContracted(worktree.path),
                    head: worktree.head,
                    isMain: worktree.isMain
                )
            }
            .sorted { lhs, rhs in
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
            }
    }

    /// `target` relative to `base`, both absolute: `..` for each of `base`'s
    /// components below their deepest shared directory, then the rest of
    /// `target`. nil when they share nothing but `/`, where a relative path
    /// would only climb to the root and back down.
    static func relativePath(from base: String, to target: String) -> String? {
        let from = base.split(separator: "/")
        let to = target.split(separator: "/")
        let shared = zip(from, to).prefix { $0 == $1 }.count
        guard shared > 0 else { return nil }
        let parts = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared).map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    // MARK: - Git metadata

    /// A worktree as git's metadata records it, before it is placed relative
    /// to the project root.
    private struct Recorded {
        let path: String
        let head: GitWorktree.Head?
        let isMain: Bool
    }

    /// The root's git dir: `.git` itself, or where a `.git` file points.
    private static func gitDir(atRoot root: String) -> String? {
        let dotGit = root + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let line = firstLine(of: dotGit), line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let gitDir = absolute(target, relativeTo: root)
        return isExistingDirectory(gitDir) ? gitDir : nil
    }

    private static func commonDir(forGitDir gitDir: String) -> String {
        guard let common = firstLine(of: gitDir + "/commondir"), !common.isEmpty else { return gitDir }
        return absolute(common, relativeTo: gitDir)
    }

    private static func mainWorktreePath(commonDir: String) -> String? {
        let config = GitConfig(commonDir: commonDir)
        if config.bool("core.bare") == true { return nil }
        let path: String
        if let worktree = config.string("core.worktree"), !worktree.isEmpty {
            path = absolute(worktree, relativeTo: commonDir)
        } else if (commonDir as NSString).lastPathComponent == ".git" {
            path = (commonDir as NSString).deletingLastPathComponent
        } else {
            return nil
        }
        return isExistingDirectory(path) ? path : nil
    }

    private static func linkedWorktrees(commonDir: String) -> [Recorded] {
        let adminRoot = commonDir + "/worktrees"
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: adminRoot) else { return [] }
        return ids.compactMap { id in
            let admin = adminRoot + "/" + id
            guard let gitFile = firstLine(of: admin + "/gitdir"), !gitFile.isEmpty else { return nil }
            let dotGit = absolute(gitFile, relativeTo: admin)
            guard FileManager.default.fileExists(atPath: dotGit) else { return nil }
            return Recorded(
                path: (dotGit as NSString).deletingLastPathComponent,
                head: head(at: admin + "/HEAD"),
                isMain: false
            )
        }
    }

    private static func head(at path: String) -> GitWorktree.Head? {
        guard let line = firstLine(of: path), !line.isEmpty else { return nil }
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let branchPrefix = "refs/heads/"
            return .branch(ref.hasPrefix(branchPrefix) ? String(ref.dropFirst(branchPrefix.count)) : ref)
        }
        return line.allSatisfy(\.isHexDigit) ? .detached(line) : nil
    }

    // MARK: - Paths

    /// Git's metadata files each hold a single line; nil when unreadable.
    private static func firstLine(of path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        URL(fileURLWithPath: path.hasPrefix("/") ? path : base + "/" + path).standardizedFileURL.path
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Every symlink resolved (`/tmp` → `/private/tmp`), and on a
    /// case-insensitive volume the on-disk case — what makes two spellings of
    /// one directory compare equal. A path that can't be resolved is kept.
    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}

/// The few git config values the worktree listing reads, parsed from the
/// INI-style files git writes. Deliberately partial — top-level sections
/// only, one-line values, no `include` — which covers `core.bare`,
/// `core.worktree` and `extensions.worktreeConfig` as git writes them.
private struct GitConfig {
    /// `section.key`, lowercased, to its value; a later line wins, as in git.
    private var values: [String: String] = [:]

    init(commonDir: String) {
        load(commonDir + "/config")
        // With the extension on, the main worktree's own `core.bare` and
        // `core.worktree` belong in `config.worktree`, read after `config`.
        if bool("extensions.worktreeconfig") == true {
            load(commonDir + "/config.worktree")
        }
    }

    func string(_ key: String) -> String? {
        values[key]
    }

    /// Git's boolean spellings; nil when unset or not a boolean.
    func bool(_ key: String) -> Bool? {
        guard let value = values[key]?.lowercased() else { return nil }
        switch value {
        case "true",
             "yes",
             "on": return true
        case "false",
             "no",
             "off",
             "": return false
        default: return Int(value).map { $0 != 0 }
        }
    }

    private mutating func load(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.drop { $0.isWhitespace }
            if line.first == "[" {
                guard let close = line.firstIndex(of: "]") else {
                    section = nil
                    continue
                }
                let header = line[line.index(after: line.startIndex) ..< close]
                // `[remote "origin"]` and the legacy `[branch.main]` name a
                // subsection; nothing read here lives in one.
                let hasSubsection = header.contains { $0.isWhitespace || $0 == "\"" || $0 == "." }
                section = hasSubsection ? nil : header.lowercased()
                // A key may follow the header on the same line.
                line = line[line.index(after: close)...].drop { $0.isWhitespace }
            }
            guard let section, line.first?.isLetter == true else { continue }
            let (name, value) = Self.entry(line)
            values[section + "." + name.lowercased()] = value
        }
    }

    /// One `name = value` line, value unquoted and unescaped, with git's
    /// rules: surrounding whitespace dropped, `#` or `;` outside quotes
    /// starting a comment, and a bare `name` meaning true.
    private static func entry(_ line: Substring) -> (name: String, value: String) {
        let name = line.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        var rest = line[name.endIndex...].drop { $0.isWhitespace }
        guard rest.first == "=" else { return (String(name), "true") }
        rest = rest.dropFirst()
        var value = ""
        var quoted = false
        // Where the value ends if only unquoted whitespace follows.
        var trimmedLength: Int?
        var characters = rest.makeIterator()
        while let character = characters.next() {
            if character.isWhitespace, !quoted {
                if trimmedLength == nil { trimmedLength = value.count }
                if !value.isEmpty { value.append(character) }
                continue
            }
            if !quoted, character == "#" || character == ";" { break }
            trimmedLength = nil
            switch character {
            case "\\":
                guard let escaped = characters.next() else { break }
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "b": value.append("\u{8}")
                default: value.append(escaped)
                }
            case "\"":
                quoted.toggle()
            default:
                value.append(character)
            }
        }
        if let trimmedLength { value = String(value.prefix(trimmedLength)) }
        return (String(name), value)
    }
}
