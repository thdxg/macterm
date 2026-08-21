import Foundation

// Pure parsing for the repository-changes panel: everything here turns git's
// machine-readable output into values, with no process launching and no
// isolation, so the shapes that actually bite (renames, NUL framing, quoted
// paths) are unit-testable without a repository on disk. `GitClient` owns the
// process side; this file must stay free of it.

/// One path git reports as changed, carrying BOTH halves of git's two-column
/// status: a file can be staged and dirty at once (`MM`), and collapsing that
/// into a single state is what makes a changes list lie about what a commit
/// would capture.
struct GitFileChange: Identifiable, Equatable {
    /// What happened to a path on one side (index or working tree).
    enum State: Equatable {
        case added
        case modified
        case deleted
        case renamed(from: String)
        case copied(from: String)
        case typeChanged
        case untracked
        case ignored
        case conflicted
    }

    var id: String { path }
    let path: String
    /// Staged side (git's X column) — nil when the index matches HEAD.
    let index: State?
    /// Unstaged side (git's Y column) — nil when the working tree matches the
    /// index.
    let worktree: State?
    var additions: Int = 0
    var deletions: Int = 0

    var isStaged: Bool { index != nil }
    var isConflicted: Bool { index == .conflicted || worktree == .conflicted }

    /// The state a single-line row should show: the working tree's, falling
    /// back to the index's. A `MM` row reads as modified either way; an `AM`
    /// row reads as modified, which is what its working tree says.
    var displayState: State {
        worktree ?? index ?? .modified
    }

    /// The last path component, for a row that shows the name big and the
    /// directory small.
    var fileName: String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// True for formats AppKit can decode, which is what decides whether the
    /// panel shows a picture instead of a diff. SVG is deliberately absent: it
    /// is text, and its diff is the useful view of it.
    var isImage: Bool {
        let ext = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "ico", "webp"].contains(ext)
    }

    /// Everything before the file name, without a trailing slash.
    var directory: String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/")
    }
}

enum GitStatusParser {
    /// Parse `git status --porcelain=v1 -z --untracked-files=all`.
    ///
    /// `-z` matters for more than exotic filenames: without it git *quotes*
    /// any path holding a space or non-ASCII byte, so the panel would show
    /// `"src/my file.swift"` (quotes included) and every later lookup keyed on
    /// that path would miss. NUL framing has no quoting and no escaping.
    ///
    /// Framing is `XY <path>` per entry, and a rename or copy appends its
    /// ORIGIN as a second, separate NUL field — so the parser must consume two
    /// fields for those and one for everything else. Reading it as one field
    /// per entry silently shifts every subsequent row by one.
    static func parse(porcelain: String) -> [GitFileChange] {
        var changes: [GitFileChange] = []
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < fields.count {
            let entry = fields[i]
            i += 1
            // "XY path": two status columns, a space, then the path. Anything
            // shorter than that is not an entry git produced.
            guard entry.count > 3 else { continue }
            let codes = Array(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            let x = codes[0]
            let y = codes[1]

            var origin: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < fields.count {
                    origin = fields[i]
                    i += 1
                }
            }
            if x == "?", y == "?" {
                changes.append(GitFileChange(path: path, index: nil, worktree: .untracked))
                continue
            }
            if x == "!", y == "!" {
                changes.append(GitFileChange(path: path, index: nil, worktree: .ignored))
                continue
            }
            // Both columns lettered with the same letter (DD, AA), or either
            // column a U, is a conflict — never a staged change plus a dirty
            // file, and a commit would refuse it.
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                changes.append(GitFileChange(path: path, index: .conflicted, worktree: .conflicted))
                continue
            }
            changes.append(GitFileChange(
                path: path,
                index: state(for: x, origin: origin),
                worktree: state(for: y, origin: origin)
            ))
        }
        return changes
    }

    private static func state(for code: Character, origin: String?) -> GitFileChange.State? {
        switch code {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed(from: origin ?? "")
        case "C": .copied(from: origin ?? "")
        case "T": .typeChanged
        case "?": .untracked
        case "!": .ignored
        case "U": .conflicted
        default: nil // ' ' — that side is clean
        }
    }

    /// Parse `git diff --numstat -z` into per-path line counts.
    ///
    /// The framing is entry-shaped, not line-shaped, and the two cases differ:
    /// an ordinary entry is ONE field, `"12\t3\tsrc/a.swift"`, while a rename
    /// leaves that third component EMPTY and spends two further fields on the
    /// old and new paths (no `=>` arrow, unlike the human form). Counts are
    /// keyed on the new path, which is what the status rows carry. Binary
    /// files report `-` for both counts, which reads as zero here rather than
    /// as a parse failure that would drop the row entirely.
    static func parseNumstat(_ raw: String) -> [String: (additions: Int, deletions: Int)] {
        var counts: [String: (additions: Int, deletions: Int)] = [:]
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            i += 1
            guard parts.count >= 2 else { continue }
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            var path: String?
            if parts.count >= 3, !parts[2].isEmpty {
                path = parts[2]
            } else if i + 1 < fields.count {
                // Rename: the old path, then the new one. Skip the old — the
                // status row this pairs with is keyed on the new path.
                i += 1
                path = fields[i]
                i += 1
            }
            guard let path else { continue }
            counts[path] = (additions, deletions)
        }
        return counts
    }
}

/// One rendered line of a unified diff, already classified — and numbered — so
/// the view does no string sniffing while scrolling.
struct GitDiffLine: Identifiable {
    enum Kind {
        case addition
        case deletion
        case context
        case hunk
        case meta
    }

    let id: Int
    let kind: Kind
    let text: String
    /// The line's code, already tokenized. Computed ONCE here, off the render
    /// path: doing it in a SwiftUI `body` re-tokenizes on every layout pass,
    /// which pegged the main thread at 100% on an ordinary diff.
    var tokens: [SyntaxToken] = []
    /// Line number in the pre-image; nil for additions and for anything that
    /// isn't a content line.
    var oldLine: Int?
    /// Line number in the post-image; nil for deletions and non-content lines.
    var newLine: Int?

    /// The single number a one-column gutter shows: where the line IS after
    /// the change, or where it was when it no longer exists.
    var displayNumber: Int? { newLine ?? oldLine }
}

enum GitDiffParser {
    /// Classify a unified diff and number its lines.
    ///
    /// Order matters: `+++`/`---` are file headers that start with the same
    /// characters as added and deleted lines, so they must be recognized
    /// BEFORE the +/- test or every diff shows two bogus changed lines at the
    /// top of each file.
    ///
    /// Numbering can only come from the hunk headers — a diff carries no line
    /// numbers of its own — so `@@ -a,b +c,d @@` seeds two counters that then
    /// advance per line: context advances both, an addition only the new side,
    /// a deletion only the old. Getting that wrong doesn't fail loudly; it
    /// quietly prints numbers that don't match the file.
    /// `tokenLimit` bounds the syntax pass: classification and numbering are
    /// cheap and run for every line (the counts and the "N more lines" footer
    /// depend on them), but tokenizing is not, and the view renders only the
    /// first few thousand rows anyway. Tokenizing a 40k-line lockfile diff
    /// nobody will scroll to is pure latency.
    static func lines(_ raw: String, language: SyntaxLanguage = .plain, tokenLimit: Int = .max) -> [GitDiffLine] {
        var result: [GitDiffLine] = []
        var oldCounter = 0
        var newCounter = 0
        for (index, rawLine) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(rawLine)
            var line = GitDiffLine(id: index, kind: kind(of: text), text: text)
            switch line.kind {
            case .hunk:
                let starts = hunkStarts(text)
                oldCounter = starts.old
                newCounter = starts.new
            case .context:
                line.oldLine = oldCounter
                line.newLine = newCounter
                oldCounter += 1
                newCounter += 1
            case .addition:
                line.newLine = newCounter
                newCounter += 1
            case .deletion:
                line.oldLine = oldCounter
                oldCounter += 1
            case .meta:
                break
            }
            // The marker column (`+`, `-`, or the context space) is git's, not
            // the file's — tokenizing it would make every added line start
            // with a stray operator.
            if line.kind != .hunk, line.kind != .meta, !text.isEmpty, result.count < tokenLimit {
                line.tokens = SyntaxHighlighter.tokens(for: String(text.dropFirst()), language: language)
            }
            result.append(line)
        }
        return result
    }

    /// Read the two starting line numbers out of `@@ -a,b +c,d @@`. The counts
    /// are optional in the format (`@@ -1 +1 @@` is legal for a one-line
    /// range), so only the numbers after the sign markers are read.
    private static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        var old = 0
        var new = 0
        for field in header.split(separator: " ") {
            let digits = field.dropFirst().prefix { $0.isNumber }
            guard let value = Int(digits) else { continue }
            if field.hasPrefix("-"), old == 0 { old = value }
            if field.hasPrefix("+"), new == 0 { new = value }
        }
        return (old, new)
    }

    private static func kind(of line: String) -> GitDiffLine.Kind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .meta }
        if line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename ")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode")
            || line.hasPrefix("Binary files")
        {
            return .meta
        }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .deletion }
        return .context
    }
}
