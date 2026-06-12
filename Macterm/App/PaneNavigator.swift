import Foundation

/// Browser-style back/forward history over focused pane IDs.
///
/// A linear trail of visited panes with a cursor. A normal focus change
/// (`record`) truncates anything after the cursor — visiting B then C after
/// going back to A discards the old forward path, exactly like a web browser.
/// `back`/`forward` move the cursor without mutating the trail, so Back then
/// Forward returns you where you were.
///
/// This is deliberately separate from the MRU `RecencyStack` that drives
/// next-focus-after-close: that one answers "what's the most recent *other*
/// live pane", whereas this one answers "where did I navigate from / to".
struct PaneNavigator<ID: Hashable & Codable>: Codable {
    private(set) var trail: [ID] = []
    private(set) var cursor: Int = -1
    let limit: Int

    init(limit: Int = 50) {
        self.limit = limit
    }

    /// The pane the cursor currently points at, if any.
    var current: ID? {
        trail.indices.contains(cursor) ? trail[cursor] : nil
    }

    /// Record a normal (non-navigation) focus change. No-op if it's already
    /// the current entry. Drops the forward trail, appends the id, and clamps
    /// the trail to `limit` (keeping the most recent entries).
    mutating func record(_ id: ID) {
        if current == id { return }
        // Drop anything after the cursor — a new branch invalidates the
        // forward path.
        if cursor < trail.count - 1 {
            trail.removeSubrange((cursor + 1)...)
        }
        trail.append(id)
        if trail.count > limit {
            trail.removeFirst(trail.count - limit)
        }
        cursor = trail.count - 1
    }

    /// Step the cursor back and return the pane there, or nil at the start.
    mutating func back() -> ID? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return trail[cursor]
    }

    /// Step the cursor forward and return the pane there, or nil at the end.
    mutating func forward() -> ID? {
        guard cursor < trail.count - 1 else { return nil }
        cursor += 1
        return trail[cursor]
    }

    /// Drop any entries not in `valid` (e.g. closed panes), keeping the cursor
    /// pointing at the same trail slot where possible. Re-anchors by position,
    /// not value — the trail may hold duplicate ids (browser-style), so a value
    /// match would land on the wrong occurrence.
    mutating func prune(keeping valid: Set<ID>) {
        guard !trail.isEmpty else { cursor = -1
            return
        }
        // Count how many surviving entries sit at or before the cursor so we
        // can place the cursor on the same logical slot afterward.
        let survivorsUpToCursor = cursor >= 0
            ? trail[...cursor].reduce(0) { $0 + (valid.contains($1) ? 1 : 0) }
            : 0
        trail.removeAll { !valid.contains($0) }
        cursor = min(max(survivorsUpToCursor - 1, trail.isEmpty ? -1 : 0), trail.count - 1)
    }
}
