import Foundation

/// A file reference as terminal output prints it — `src/app.ts:42:7`, the
/// form compilers, test runners, linters and agents use — split into the path
/// and the position after it.
///
/// libghostty's link regex matches these whole, `:line:col` included, and
/// hands the text to `GHOSTTY_ACTION_OPEN_URL` unresolved unless that exact
/// string exists on disk, so a path with a line never opened anything:
/// `foo.swift:42` even parses as a URL with the scheme `foo.swift`. Upstream
/// has said it will at most stop matching the suffix, so a text without one
/// must keep working too — it is simply a link with no line.
struct FileLink: Equatable {
    var path: String
    var line: Int?
    var column: Int?

    /// The reference `text` names, or nil when it is a URL rather than a path
    /// (`https://host:8080`, `mailto:…`, `file://…`) — those stay with the
    /// system opener.
    static func parse(_ text: String) -> FileLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var link = FileLink(path: trimmed)
        if let match = trimmed.firstMatch(of: #/:(\d+)(?::(\d+))?$/#) {
            link.path = String(trimmed[..<match.range.lowerBound])
            link.line = Int(match.output.1)
            link.column = match.output.2.flatMap { Int($0) }
        }
        guard !link.path.isEmpty,
              !link.path.contains("://"),
              link.path.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:/#) == nil
        else { return nil }
        // A zero line is no line: editors disagree on what `+0` means.
        if link.line == 0 { link.line = nil }
        return link
    }

    /// The same reference with an absolute path: `~` expanded, and a relative
    /// path taken from `directory` — the pane's working directory, which is
    /// what the program printing it was relative to. A relative path with no
    /// directory stays relative, and so names no file.
    func resolved(against directory: String?) -> FileLink {
        var copy = self
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            copy.path = (expanded as NSString).standardizingPath
        } else if let directory, directory.hasPrefix("/") {
            copy.path = ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        return copy
    }
}
