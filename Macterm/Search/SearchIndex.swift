import Foundation

/// One whitespace-separated word of a query, folded like `SearchText`.
struct SearchTerm: Equatable {
    let scalars: [UInt32]
    let mask: UInt64

    init(_ word: some StringProtocol) {
        scalars = SearchText.foldedScalars(word)
        mask = SearchText.mask(of: scalars)
    }
}

/// What the user typed, split into terms. Every term must match (in any of a
/// record's fields) for the record to match — fzf's extended syntax without
/// its operators — so `split right` finds Split Right whichever word was
/// typed first.
struct SearchQuery: Equatable {
    let terms: [SearchTerm]

    init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(SearchTerm.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Whether everything `self` matches is among what `previous` matched:
    /// each earlier term only grew at its end (a subsequence's prefix is a
    /// subsequence of the same field), and any new term only narrows. True
    /// lets a keystroke search the last result instead of the whole list.
    func narrows(_ previous: SearchQuery) -> Bool {
        guard terms.count >= previous.terms.count else { return false }
        return zip(terms, previous.terms).allSatisfy { new, old in new.scalars.starts(with: old.scalars) }
    }
}

/// A match in a `SearchIndex`: the record's position in the list it was built
/// from, and its score (higher is better).
struct SearchMatch: Equatable {
    let index: Int
    let score: Int32
}

/// The one search engine behind every search in the app: a list of records,
/// each one or more fields (the first is the one shown; a match there is worth
/// a little more), prepared once and matched with fzf's scoring.
///
/// Built for long lists. Preparation happens once per list, not per keystroke;
/// a record whose character mask lacks one of a term's characters is
/// rejected with one AND, and one forward scan rejects the rest of the
/// non-matches before any scoring; the scoring DP runs only over the window a
/// match can occupy; past `parallelThreshold` records the work is split across
/// cores; and `search(limit:)` keeps the order of the best `limit` only.
/// `SearchSession` adds narrowing: a keystroke that extends the query searches
/// only what the last one matched.
final class SearchIndex: Sendable {
    let records: [[SearchText]]

    /// A record's later fields cost this much per position after the first,
    /// so a title match outranks the same match in a subtitle or a path.
    static let fieldPenalty: Int32 = 8
    static let parallelThreshold = 4096

    /// Prepares every record's fields — across cores past
    /// `parallelThreshold`, since a plugin's list can be long and this is the
    /// one pass over its full text.
    init(_ records: [[String]]) {
        guard records.count >= Self.parallelThreshold else {
            self.records = records.map { $0.map(SearchText.init) }
            return
        }
        let prepared = SharedBuffer<[SearchText]>(count: records.count, initial: [])
        let chunkSize = Self.chunkSize(for: records.count)
        DispatchQueue.concurrentPerform(iterations: (records.count + chunkSize - 1) / chunkSize) { chunk in
            let lower = chunk * chunkSize
            for index in lower ..< min(lower + chunkSize, records.count) {
                prepared[index] = records[index].map(SearchText.init)
            }
        }
        self.records = prepared.array()
    }

    private static func chunkSize(for total: Int) -> Int {
        max(1024, total / (ProcessInfo.processInfo.activeProcessorCount * 4))
    }

    init(prepared: [[SearchText]]) {
        records = prepared
    }

    var count: Int { records.count }

    /// `index`'s score for `query`, or nil when some term matches none of its
    /// fields. An empty query matches everything with 0.
    func score(_ query: SearchQuery, at index: Int, scratch: SearchScratch) -> Int32? {
        Self.score(query, fields: records[index], scratch: scratch)
    }

    static func score(_ query: SearchQuery, fields: [SearchText], scratch: SearchScratch) -> Int32? {
        var total: Int32 = 0
        for term in query.terms {
            var best: Int32?
            for (position, field) in fields.enumerated() {
                guard let score = SearchScoring.score(term, in: field, scratch: scratch) else { continue }
                let weighted = score - Int32(position) * fieldPenalty
                if best.map({ weighted > $0 }) ?? true { best = weighted }
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// The records `query` matches, best first: by score, then the shorter
    /// first field (fzf's tiebreak), then list order. With `limit`, only the
    /// best `limit`. `among` restricts the search to those indices (a
    /// session's last matches).
    func search(_ query: SearchQuery, limit: Int? = nil, among: [Int]? = nil) -> [SearchMatch] {
        rank(matchAll(query, among: among), limit: limit)
    }

    /// The records `query` matches, in list order — a filter for a list that
    /// keeps its own order (Settings).
    func filter(_ query: SearchQuery) -> [Int] {
        matchAll(query, among: nil).map(\.index)
    }

    /// Every match, unordered, in parallel when the list is long.
    func matchAll(_ query: SearchQuery, among: [Int]?) -> [SearchMatch] {
        let total = among?.count ?? records.count
        if query.isEmpty {
            return (0 ..< total).map { SearchMatch(index: among?[$0] ?? $0, score: 0) }
        }
        guard total >= Self.parallelThreshold else {
            return Self.matchRange(0 ..< total, query: query, records: records, among: among)
        }
        let chunkSize = Self.chunkSize(for: total)
        let chunks = (total + chunkSize - 1) / chunkSize
        let results = SharedBuffer<[SearchMatch]>(count: chunks, initial: [])
        let records = records
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * chunkSize
            let range = lower ..< min(lower + chunkSize, total)
            results[chunk] = Self.matchRange(range, query: query, records: records, among: among)
        }
        return Array(results.array().joined())
    }

    private static func matchRange(
        _ range: Range<Int>,
        query: SearchQuery,
        records: [[SearchText]],
        among: [Int]?
    ) -> [SearchMatch] {
        let scratch = SearchScratch()
        var out: [SearchMatch] = []
        for position in range {
            let index = among?[position] ?? position
            if let score = score(query, fields: records[index], scratch: scratch) {
                out.append(SearchMatch(index: index, score: score))
            }
        }
        return out
    }

    /// `matches` best first (see `search`), the best `limit` only when given.
    func rank(_ matches: [SearchMatch], limit: Int?) -> [SearchMatch] {
        let ordered: (SearchMatch, SearchMatch) -> Bool = { [records] lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = records[lhs.index].first?.length ?? 0
            let rhsLength = records[rhs.index].first?.length ?? 0
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.index < rhs.index
        }
        guard let limit, limit < matches.count else { return matches.sorted(by: ordered) }
        // The best `limit` without sorting the rest: a bounded insertion into
        // a sorted prefix, which for a short limit over a long list is far
        // cheaper than sorting every match.
        var top: [SearchMatch] = []
        top.reserveCapacity(limit + 1)
        for match in matches {
            if top.count == limit, let worst = top.last, !ordered(match, worst) { continue }
            let at = top.firstIndex { ordered(match, $0) } ?? top.endIndex
            top.insert(match, at: at)
            if top.count > limit { top.removeLast() }
        }
        return top
    }

    /// Scalar offsets in record `index`'s first field (its title) that
    /// `query`'s terms matched, for highlighting: each term's best alignment
    /// there, for the terms that match the title at all.
    func highlights(_ query: SearchQuery, at index: Int) -> [Int] {
        guard let title = records[index].first else { return [] }
        return Self.highlights(query, in: title)
    }

    static func highlights(_ query: SearchQuery, in title: SearchText) -> [Int] {
        var offsets = Set<Int>()
        for term in query.terms {
            guard let positions = SearchScoring.positions(term, in: title) else { continue }
            for position in positions {
                offsets.insert(Int(title.sourceOffsets[position]))
            }
        }
        return offsets.sorted()
    }
}

/// Slots that concurrent workers each write one of, never the same one — what
/// `concurrentPerform` needs and Swift's checker can't see.
private final class SharedBuffer<Element>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Element>

    init(count: Int, initial: Element) {
        storage = .allocate(capacity: count)
        storage.initialize(repeating: initial)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    subscript(index: Int) -> Element {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    func array() -> [Element] {
        Array(storage)
    }
}

/// A `SearchIndex` searched keystroke by keystroke: when the new query only
/// narrows the last one (`SearchQuery.narrows`), only the last query's matches
/// are searched. Not thread-safe — one per search field.
final class SearchSession {
    let index: SearchIndex
    private var lastQuery: SearchQuery?
    private var lastMatches: [Int] = []

    init(index: SearchIndex) {
        self.index = index
    }

    func search(_ text: String, limit: Int? = nil) -> [SearchMatch] {
        let query = SearchQuery(text)
        let among = lastQuery.flatMap { query.narrows($0) ? lastMatches : nil }
        let all = index.matchAll(query, among: among)
        lastQuery = query
        lastMatches = all.map(\.index)
        return index.rank(all, limit: limit)
    }
}

/// The engine for a short list built on the spot (the palette's commands,
/// projects, saved passwords, worktrees; a Settings list), where preparing an
/// index first buys nothing. Same scoring and folding as `SearchIndex`.
enum Search {
    struct Match {
        /// Higher is better.
        let score: Int32
        /// Scalar offsets in the first field the query matched, for highlighting.
        let highlights: [Int]
    }

    /// `fields`' match for `query` (the first field is the one shown), or nil.
    /// An empty query matches with 0 and nothing highlighted.
    static func match(_ query: SearchQuery, fields: [String]) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, highlights: []) }
        let prepared = fields.map(SearchText.init)
        guard let score = SearchIndex.score(query, fields: prepared, scratch: SearchScratch()) else { return nil }
        let highlights = prepared.first.map { SearchIndex.highlights(query, in: $0) } ?? []
        return Match(score: score, highlights: highlights)
    }

    static func match(_ text: String, fields: [String]) -> Match? {
        match(SearchQuery(text), fields: fields)
    }

    /// The `items` `text` matches, best first (ties keep list order) — a
    /// Settings list while it's searched. Ranked, not just filtered, because
    /// fuzzy matching admits letters scattered across words: unranked, such a
    /// row would sit beside a strong match with nothing to tell them apart.
    /// An empty query returns `items` as they are.
    static func rank<Item>(_ items: [Item], by text: String, fields: (Item) -> [String]) -> [Item] {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return items }
        let scratch = SearchScratch()
        return items.enumerated()
            .compactMap { offset, item -> (score: Int32, offset: Int)? in
                SearchIndex.score(query, fields: fields(item).map(SearchText.init), scratch: scratch).map { ($0, offset) }
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map { items[$0.offset] }
    }

    /// Whether `text` matches any of `fields`.
    static func matches(_ text: String, in fields: [String]) -> Bool {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return true }
        return SearchIndex.score(query, fields: fields.map(SearchText.init), scratch: SearchScratch()) != nil
    }

    /// Whether `text` starts with `prefix`, folded the engine's way — the
    /// palette's path completion, which completes rather than searches.
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        SearchText.foldedScalars(text).starts(with: SearchText.foldedScalars(prefix))
    }
}
