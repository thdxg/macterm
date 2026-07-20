import Foundation

/// Computes which scrollback rows contain search matches, for the scrollbar
/// tick overlay. libghostty's search only reports match *counts*
/// (`SEARCH_TOTAL`/`SEARCH_SELECTED`), never positions, so rows are recovered
/// Macterm-side: scan the scrollback text (`ghostty_surface_read_text`) with
/// the same ASCII-case-insensitive literal match ghostty's search uses
/// (`std.ascii.indexOfIgnoreCase`), re-wrapping logical lines at the surface
/// width to map text offsets onto visual rows.
enum SearchTicks {
    /// One entry per match (rows repeat when a row holds several matches, so
    /// indices stay 1:1 with ghostty's match list), each the 0-based visual
    /// row — counted from the top of history — where the match starts.
    ///
    /// Columns are counted as UTF-8 code points; a double-width cell drifts a
    /// tick by one row at most, invisible at scrollbar scale. Matches are
    /// non-overlapping, mirroring ghostty's sliding-window scan.
    static func matchRows(text: String, needle: String, cols: Int) -> [Int] {
        guard cols > 0, !needle.isEmpty, !needle.contains("\n") else { return [] }
        let hay = Array(text.utf8)
        let ndl = Array(needle.utf8).map(asciiLower)
        let needleCodePoints = ndl.count(where: isCodePointStart)

        var rows: [Int] = []
        var lineRow = 0 // visual row where the current logical line starts
        var cpInLine = 0 // code points consumed within the current logical line
        var i = 0
        while i < hay.count {
            if hay[i] == UInt8(ascii: "\n") {
                lineRow += rowsConsumed(byLineOf: cpInLine, cols: cols)
                cpInLine = 0
                i += 1
                continue
            }
            if matches(hay, at: i, needle: ndl) {
                rows.append(lineRow + cpInLine / cols)
                i += ndl.count
                cpInLine += needleCodePoints
                continue
            }
            if isCodePointStart(hay[i]) { cpInLine += 1 }
            i += 1
        }
        return rows
    }

    /// Map ghostty's selected index — counted from the *end* of the match list
    /// (0 = newest, bottom-most) — onto `matchRows` output. nil when there is
    /// no selection or our scan disagrees with ghostty's count (index out of
    /// range): the ticks still draw, just without a selected highlight.
    static func selectedRow(rows: [Int], selectedFromEnd: Int?) -> Int? {
        guard let idx = selectedFromEnd, idx >= 0, idx < rows.count else { return nil }
        return rows[rows.count - 1 - idx]
    }

    /// Rows a logical line of `codePoints` occupies when soft-wrapped at
    /// `cols`. An empty line still occupies one row.
    private static func rowsConsumed(byLineOf codePoints: Int, cols: Int) -> Int {
        max(1, (codePoints + cols - 1) / cols)
    }

    private static func matches(_ hay: [UInt8], at i: Int, needle: [UInt8]) -> Bool {
        guard i + needle.count <= hay.count else { return false }
        for j in 0 ..< needle.count where asciiLower(hay[i + j]) != needle[j] {
            return false
        }
        return true
    }

    private static func asciiLower(_ b: UInt8) -> UInt8 {
        b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b + 32 : b
    }

    /// True for any byte that begins a UTF-8 code point (not a continuation).
    private static func isCodePointStart(_ b: UInt8) -> Bool {
        b & 0xC0 != 0x80
    }
}
