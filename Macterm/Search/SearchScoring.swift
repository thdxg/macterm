import Foundation

/// fzf's scoring (its `FuzzyMatchV2`): a match is worth `match` per
/// character, plus a bonus where it lands — the start of a word, a path
/// component, a camelCase hump — and consecutive characters carry the bonus
/// of the run's first; skipping characters between two matches costs a gap
/// penalty. Unmatched text before the first match and after the last costs
/// nothing. Higher is better.
///
/// The constants are fzf's, so the ranking is the one a terminal user's hands
/// already know: `sr` finds **S**plit **R**ight before a word that merely
/// contains an s and an r, and a run of matched characters beats the same
/// characters scattered.
enum SearchScoring {
    static let match: Int32 = 16
    static let gapStart: Int32 = -3
    static let gapExtension: Int32 = -1
    static let boundary: Int16 = 8
    static let nonWord: Int16 = 8
    static let camel: Int16 = 7
    static let consecutive: Int32 = 4
    static let firstCharMultiplier: Int32 = 2
    static let boundaryWhite: Int16 = 10
    static let boundaryDelimiter: Int16 = 9

    /// What matching a character of class `current` is worth when the one
    /// before it is `previous` — fzf's `bonusFor`.
    static func bonus(previous: CharClass, current: CharClass) -> Int16 {
        if current.isWord {
            switch previous {
            case .white: return boundaryWhite
            case .delimiter: return boundaryDelimiter
            case .nonWord: return boundary
            default: break
            }
        }
        if previous == .lower && current == .upper || previous != .number && current == .number {
            return camel
        }
        switch current {
        case .nonWord,
             .delimiter: return nonWord
        case .white: return boundaryWhite
        default: return 0
        }
    }

    /// Below any real score, with room to add to it without overflowing.
    static let none = Int32.min / 4

    /// The best score of `term` as a subsequence of `text`, or nil when it
    /// isn't one. `scratch` is reused across calls so a long list allocates
    /// nothing per candidate.
    static func score(_ term: SearchTerm, in text: SearchText, scratch: SearchScratch) -> Int32? {
        let m = term.scalars.count
        if m == 0 { return 0 }
        guard text.mask & term.mask == term.mask else { return nil }
        let n = text.scalars.count
        guard n >= m else { return nil }
        return text.scalars.withUnsafeBufferPointer { t in
            text.bonus.withUnsafeBufferPointer { b in
                term.scalars.withUnsafeBufferPointer { q in
                    scratch.reserve(rows: m, columns: n)
                    // Where each term character can first match, greedily:
                    // no alignment can place q[i] earlier than first[i].
                    let first = scratch.first
                    var pi = 0
                    var j = 0
                    while j < n, pi < m {
                        if t[j] == q[pi] {
                            first[pi] = Int32(j)
                            pi += 1
                        }
                        j += 1
                    }
                    guard pi == m else { return nil }
                    // ...and the last character can match no later than its
                    // last occurrence: the DP only ever looks at this window.
                    var last = n - 1
                    while t[last] != q[m - 1] {
                        last -= 1
                    }
                    return fill(q: q, t: t, b: b, window: Int(first[0]) ... last, scratch: scratch)
                }
            }
        }
    }

    /// The DP over `t[window]`, two rows at a time, `scratch.first` holding
    /// each term character's earliest possible column. Per row `i`:
    /// `matched[c]` is the best score with q[i] matched exactly at column c,
    /// `gapped[c]` the best with q[i] matched somewhere before c and every
    /// character since skipped, `chunk[c]` the bonus of the consecutive run
    /// ending at a match in c.
    private static func fill(
        q: UnsafeBufferPointer<UInt32>,
        t: UnsafeBufferPointer<UInt32>,
        b: UnsafeBufferPointer<Int16>,
        window: ClosedRange<Int>,
        scratch: SearchScratch
    ) -> Int32 {
        let first = scratch.first
        let start = window.lowerBound
        let width = window.count
        var matched = scratch.matchedA, gapped = scratch.gappedA, chunk = scratch.chunkA
        var prevMatched = scratch.matchedB, prevGapped = scratch.gappedB, prevChunk = scratch.chunkB

        // Row 0: the term's first character. Its bonus counts double — where
        // a match starts says most about whether it is the one meant.
        for c in 0 ..< width {
            let j = start + c
            if t[j] == q[0] {
                let bonus = Int32(b[j])
                matched[c] = match + bonus * firstCharMultiplier
                chunk[c] = bonus
            } else {
                matched[c] = none
            }
            gapped[c] = c == 0 ? none : max(matched[c - 1] + gapStart, gapped[c - 1] + gapExtension)
        }

        for i in 1 ..< q.count {
            swap(&matched, &prevMatched)
            swap(&gapped, &prevGapped)
            swap(&chunk, &prevChunk)
            let qi = q[i]
            let from = Int(first[i]) - start
            for c in 0 ..< width {
                guard c >= from, c > 0 else {
                    matched[c] = none
                    gapped[c] = none
                    continue
                }
                let j = start + c
                if t[j] == qi {
                    let here = Int32(b[j])
                    var best = none
                    var bestChunk: Int32 = 0
                    // Consecutive with q[i-1] at c-1: the run's bonus carries,
                    // unless this character starts a stronger word itself.
                    let diagonal = prevMatched[c - 1]
                    if diagonal > none {
                        let run = prevChunk[c - 1]
                        if here >= Int32(boundary), here > run {
                            best = diagonal + match + here
                            bestChunk = here
                        } else {
                            best = diagonal + match + max(here, run, consecutive)
                            bestChunk = run
                        }
                    }
                    // After a gap: this character's own bonus only.
                    let afterGap = prevGapped[c - 1]
                    if afterGap > none, afterGap + match + here > best {
                        best = afterGap + match + here
                        bestChunk = here
                    }
                    matched[c] = best
                    chunk[c] = bestChunk
                } else {
                    matched[c] = none
                }
                gapped[c] = max(matched[c - 1] + gapStart, gapped[c - 1] + gapExtension)
            }
        }

        var best = none
        for c in 0 ..< width where matched[c] > best {
            best = matched[c]
        }
        return best
    }

    /// Where `term` matched in `text` under its best score, as indices into
    /// `text.scalars` — for highlighting, so only ever run on the rows shown.
    /// The same DP as `score`, kept whole so it can be walked back.
    static func positions(_ term: SearchTerm, in text: SearchText) -> [Int]? {
        let q = term.scalars, t = text.scalars, b = text.bonus
        let m = q.count, n = t.count
        guard m > 0, n >= m, text.mask & term.mask == term.mask else { return m == 0 ? [] : nil }
        var matched = [Int32](repeating: none, count: m * n)
        var gapped = [Int32](repeating: none, count: m * n)
        var chunk = [Int32](repeating: 0, count: m * n)
        var viaGap = [Bool](repeating: false, count: m * n)
        var gapFromMatch = [Bool](repeating: false, count: m * n)
        for i in 0 ..< m {
            for j in 0 ..< n {
                let k = i * n + j
                if t[j] == q[i] {
                    let here = Int32(b[j])
                    if i == 0 {
                        matched[k] = match + here * firstCharMultiplier
                        chunk[k] = here
                    } else if j > 0 {
                        let up = (i - 1) * n + j - 1
                        var best = none
                        if matched[up] > none {
                            let run = chunk[up]
                            if here >= Int32(boundary), here > run {
                                best = matched[up] + match + here
                                chunk[k] = here
                            } else {
                                best = matched[up] + match + max(here, run, consecutive)
                                chunk[k] = run
                            }
                        }
                        if gapped[up] > none, gapped[up] + match + here > best {
                            best = gapped[up] + match + here
                            chunk[k] = here
                            viaGap[k] = true
                        }
                        matched[k] = best
                    }
                }
                if j > 0 {
                    let fromMatch = matched[k - 1] + gapStart
                    let fromGap = gapped[k - 1] + gapExtension
                    gapped[k] = max(fromMatch, fromGap)
                    gapFromMatch[k] = fromMatch >= fromGap
                }
            }
        }
        var j = -1
        var best = none
        for c in 0 ..< n where matched[(m - 1) * n + c] > best {
            best = matched[(m - 1) * n + c]
            j = c
        }
        guard j >= 0 else { return nil }
        var out = [Int](repeating: 0, count: m)
        var i = m - 1
        while i >= 0 {
            out[i] = j
            guard i > 0 else { break }
            if viaGap[i * n + j] {
                // Walk the gap back to the match it opened from.
                var c = j - 1
                while !gapFromMatch[(i - 1) * n + c] {
                    c -= 1
                }
                j = c - 1
            } else {
                j -= 1
            }
            i -= 1
        }
        return out
    }
}

/// Buffers `SearchScoring.score` reuses, grown to the largest candidate seen.
/// One per thread: a parallel search gives each chunk its own.
final class SearchScratch {
    private(set) var first: UnsafeMutablePointer<Int32>
    private(set) var matchedA: UnsafeMutablePointer<Int32>
    private(set) var matchedB: UnsafeMutablePointer<Int32>
    private(set) var gappedA: UnsafeMutablePointer<Int32>
    private(set) var gappedB: UnsafeMutablePointer<Int32>
    private(set) var chunkA: UnsafeMutablePointer<Int32>
    private(set) var chunkB: UnsafeMutablePointer<Int32>
    private var rowCapacity = 0
    private var columnCapacity = 0

    init() {
        first = .allocate(capacity: 1)
        matchedA = .allocate(capacity: 1)
        matchedB = .allocate(capacity: 1)
        gappedA = .allocate(capacity: 1)
        gappedB = .allocate(capacity: 1)
        chunkA = .allocate(capacity: 1)
        chunkB = .allocate(capacity: 1)
    }

    deinit {
        for buffer in [first, matchedA, matchedB, gappedA, gappedB, chunkA, chunkB] {
            buffer.deallocate()
        }
    }

    func reserve(rows: Int, columns: Int) {
        if rows > rowCapacity {
            first.deallocate()
            first = .allocate(capacity: rows)
            rowCapacity = rows
        }
        if columns > columnCapacity {
            let capacity = max(columns, columnCapacity * 2)
            for keyPath in [\SearchScratch.matchedA, \.matchedB, \.gappedA, \.gappedB, \.chunkA, \.chunkB] {
                self[keyPath: keyPath].deallocate()
                self[keyPath: keyPath] = .allocate(capacity: capacity)
            }
            columnCapacity = capacity
        }
    }
}
