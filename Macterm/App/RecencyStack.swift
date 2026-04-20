import Foundation

/// Bounded most-recent-first list of unique IDs. Replaces the three ad-hoc
/// stacks we had before (project recency, tab history, pane focus history)
/// with one shared type.
///
/// Items are stored most-recent-first: `items[0]` is the most recently pushed.
/// Pushing an id that's already present moves it to the front rather than
/// duplicating it.
struct RecencyStack<ID: Hashable & Codable>: Codable {
    private(set) var items: [ID] = []
    let limit: Int

    init(limit: Int = 50, items: [ID] = []) {
        self.limit = limit
        self.items = Array(items.prefix(limit))
    }

    /// Move `id` to the front. No-op if `id` is already there.
    mutating func push(_ id: ID) {
        if items.first == id { return }
        items.removeAll { $0 == id }
        items.insert(id, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
    }

    mutating func remove(_ id: ID) {
        items.removeAll { $0 == id }
    }

    mutating func removeAll() {
        items.removeAll()
    }

    /// Drop any entries that aren't in `valid`.
    mutating func prune(keeping valid: Set<ID>) {
        items.removeAll { !valid.contains($0) }
    }

    /// Pop and return the most-recent id that's still in `valid`, discarding
    /// any stale entries encountered along the way. Destructive.
    mutating func popValid(in valid: Set<ID>) -> ID? {
        while let top = items.first {
            items.removeFirst()
            if valid.contains(top) { return top }
        }
        return nil
    }

    /// Up to `n` most-recent ids that are in `valid`, optionally excluding one.
    func top(_ n: Int, in valid: Set<ID>, excluding excluded: ID? = nil) -> [ID] {
        var out: [ID] = []
        for id in items where id != excluded && valid.contains(id) {
            out.append(id)
            if out.count == n { break }
        }
        return out
    }

    var isEmpty: Bool { items.isEmpty }
}
