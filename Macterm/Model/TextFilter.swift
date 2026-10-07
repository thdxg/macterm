import Foundation

/// How a Settings list's search field filters its rows (saved passwords,
/// keybinds): every whitespace-separated word of the query must appear in one
/// of the row's fields, ignoring case and diacritics. A filter, not a ranking
/// — the rows keep their own order. The command palette ranks instead
/// (`fuzzyScore`), since there the best match has to come first.
enum TextFilter {
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
